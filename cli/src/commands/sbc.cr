require "admiral"
require "http/client"
require "json"
require "set"
require "socket"
require "../helpers/colors"
require "../helpers/table"
require "../helpers/docker"
require "../helpers/deploy_config"
require "../helpers/dispatcher_list"
require "../helpers/hep/decoder"
require "../helpers/influxdb"
require "../helpers/net_validation"
require "../helpers/address_snapshot"
require "../helpers/va_config"

module VoIPAppz::Commands
  # Implementation namespace for the SIP plane. The public surface is
  # `sbc ingress` / `sbc egress` (src/commands/sip.cr); these are the shared
  # implementations behind those explicitly scoped branches. SQLite-backed
  # operations are reachable only through `sbc egress`, because SQLite exists
  # only on the egress.
  module Kamailio

    module DBHelper
      # WHICH BOX this command means. `voipappz sbc ingress ...` sets :ingress,
      # `voipappz sbc egress ...` sets :egress, and there is no third answer —
      # every entry point names one, so nothing here has to guess.
      #
      # It used to: `sbc` covered both boxes, so this was a LIST of containers
      # plus a second mechanism to pin one of them, and the fallback was "the
      # first running kamailio" — the ingress. That is how SQLite reads ended up
      # aimed at a box with no database.
      @@scope : Symbol = :egress

      def self.with_scope(s : Symbol, &)
        prev = @@scope
        @@scope = s
        begin
          yield
        ensure
          @@scope = prev
        end
      end

      # The one container this command applies to.
      def self.container : String
        want_ingress = @@scope == :ingress
        override_key = want_ingress ? "VA_KAMAILIO_INGRESS_CONTAINER" : "VA_KAMAILIO_EGRESS_CONTAINER"
        if forced = ENV[override_key]?
          unless forced.empty?
            return forced if VoIPAppz::Docker.running_containers.includes?(forced)
            STDERR.puts VoIPAppz::Colors.red("Configured #{override_key}=#{forced} is not running.")
            exit 1
          end
        end
        found = VoIPAppz::Docker.running_kamailios.find { |c| VoIPAppz::Docker.ingress?(c) == want_ingress }
        return found if found

        name    = want_ingress ? "kamailio-ingress (va-ingress)" : "kamailio-egress (va-egress)"
        profile = want_ingress ? "app" : "voip"
        STDERR.puts VoIPAppz::Colors.red("No #{name} container running on this node.")
        STDERR.puts VoIPAppz::Colors.dim("  It belongs to the '#{profile}' profile: voipappz up -p #{profile}")
        exit 1
      end

      SQLITE_DB_PATH     = "data/kamailio/kamailio.db"          # host path (bind-mount source)
      CONTAINER_DB_PATH  = "/var/lib/kamailio/kamailio.db"      # same DB inside the container

      # One home for these: dispatcher_list.cr owns the set numbering and the
      # managed-row tag, and both backends must agree on them or the ingress
      # file and the egress rows describe different topologies.
      MANAGED_PREFIX = VoIPAppz::DispatcherList::MANAGED_PREFIX
      # Group-2 address rows tagged with this prefix belong to the operator
      # (`sbc egress address add`), not to the YAML snapshot — sync never prunes
      # them. Everything else in group 2 is owned by config/va.yaml.
      MANUAL_PREFIX = "manual:"
      ID_INGRESS     = VoIPAppz::DispatcherList::SET_INGRESS
      ID_EGRESS      = VoIPAppz::DispatcherList::SET_EGRESS

      # Container-side SQLite — ONLY for what kamctl/kamcmd can't do natively:
      # the `domain` table (node-lite kamctl has no `domain` command), row-count
      # summaries, and sip_trace reads. Runs `sqlite3` INSIDE the kamailio
      # container (root, the module's own DB) — NEVER host sqlite3, which can't
      # write the in-container/root-owned DB ("attempt to write a readonly
      # database"). dispatcher + address go through kamctl and never reach here.
      # The container holding the SQLite DB. THE EGRESS, always.
      #
      # SQLite exists only on the egress — the ingress is a forwarder whose
      # destinations are a plain text file. Going through `container` here was a
      # real bug: it answered with whichever box the caller was scoped to, and
      # for the ingress that is a box with no database. It failed with a bare
      # "sqlite3 (in va-ingress) failed (exit 1):", and `list` was worse — it
      # reported "(no rows)" for a perfectly healthy ingress.
      def self.sqlite_container : String
        with_scope(:egress) { container }
      end

      # Read-only diagnostics for tables that kamctl cannot list (trace and
      # summaries). Runtime mutations must go through kamctl/kamcmd.
      def self.read_sql(sql : String) : String
        statement = sql.lstrip
        forbidden = /\b(INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER|PRAGMA|VACUUM|REINDEX|ATTACH|DETACH)\b/i
        # Scan with string literals blanked, or a legitimate filter value like
        # `method = 'UPDATE'` (a standard SIP method) trips the write guard.
        scannable = statement.gsub(/'(?:[^']|'')*'/, "''")
        unless (statement.upcase.starts_with?("SELECT") || statement.upcase.starts_with?("WITH")) &&
               !scannable.matches?(forbidden)
          raise ArgumentError.new("direct SQL writes are forbidden; use kamctl/kamcmd")
        end
        c = sqlite_container
        code, out = VoIPAppz::Docker.exec(
          c, ["sqlite3", "-separator", "|", CONTAINER_DB_PATH, sql])
        unless code == 0
          STDERR.puts VoIPAppz::Colors.red("sqlite3 (in #{c}) failed (exit #{code}): #{out.strip}")
          exit code
        end
        out
      end

      # A reload that collides with one already in flight is RETRIED, not
      # reported as success.
      #
      # kamailio serialises dispatcher reloads behind a lock and answers a
      # second one with "ongoing reload". This used to print "(skipped)" and
      # return true — so `sync` wrote the new data, was told the reload had
      # been dropped, and still reported "Sync complete" while kamailio went on
      # routing from the old list. Caught in CI: an empty list reloaded, then a
      # populated one written a moment later, and the box kept "No Destination
      # Sets" and 404'd every call under a green sync.
      #
      # The budget is ~20s because the lock is NOT brief: measured on kamailio
      # 5.6.2, a reload issued right after another one is refused for about ten
      # seconds. A 3s budget looked like a permanent lock and failed.
      RELOAD_RETRIES  = 24
      RELOAD_INTERVAL = 1.second

      def self.reload_one(method : String) : Bool
        # Resolved ONCE: `container` shells out to `docker ps`, and it cannot
        # change mid-retry. Inside the loop this was up to 24 `docker ps` for a
        # single contended reload, times three in reload_all.
        c = container
        RELOAD_RETRIES.times do |attempt|
          code, out = VoIPAppz::Docker.exec(c, ["kamcmd", method])

          if out.downcase.includes?("ongoing reload")
            # The in-flight reload is loading whatever was on disk when IT
            # started, which is not necessarily what we just wrote — so wait
            # for the lock and do our own.
            if attempt == RELOAD_RETRIES - 1
              puts "  #{VoIPAppz::Colors.red("reload")} #{method}: still locked by an ongoing reload after #{(RELOAD_INTERVAL * RELOAD_RETRIES).total_seconds.to_i}s"
              return false
            end
            print "  #{VoIPAppz::Colors.dim("reload")} #{method}: another reload is in flight, waiting…\r" if attempt == 0
            sleep RELOAD_INTERVAL
            next
          end

          if code == 0 && !out.downcase.includes?("error")
            suffix = attempt > 0 ? " (after #{attempt} retr#{attempt == 1 ? "y" : "ies"})" : ""
            puts "  #{VoIPAppz::Colors.green("reload")} #{method}: ok#{suffix}"
            return true
          end

          puts "  #{VoIPAppz::Colors.yellow("reload")} #{method}: failed (#{out.strip})"
          return false
        end
        false
      end

      # Which modules a box can reload is a property OF THE BOX, not of the
      # caller. The ingress loads neither permissions nor domain — firing those
      # at it was two failed RPCs per `sbc ingress reload`, reported as failures for
      # a box behaving correctly. `Ingress::Sync` had already worked around this
      # by calling reload_one("dispatcher.reload") directly; now nothing has to.
      def self.reload_modules : Array(String)
        return ["dispatcher.reload"] if @@scope == :ingress
        ["dispatcher.reload", "permissions.addressReload", "domain.reload"]
      end

      def self.reload_all : Bool
        reload_modules.map { |m| reload_one(m) }.all?
      end

      # Run kamctl inside the kamailio container against the SQLite DB — the
      # kamailio-native data path (no direct SQL from the CLI). DB_PATH feeds
      # kamctl.sqlite's sqlite3 call; kamctl.sqlite does `DBNAME=$DB_PATH`, so
      # without DB_PATH kamctl runs sqlite3 with no file and writes nowhere.
      # verbose echoes the kamctl command + output (minus kamctl's noisy
      # internal "sqlite_query:" line).
      def self.kamctl(args : Array(String), verbose : Bool = false) : {Int32, String}
        puts "  #{VoIPAppz::Colors.dim("$ kamctl #{args.join(" ")}")}" if verbose
        # sqlite_container, not container: kamctl here is DBENGINE=SQLITE, so
        # it is an egress-only path.
        command = ["env", "DBENGINE=SQLITE", "DB_PATH=#{CONTAINER_DB_PATH}", "kamctl"] + args
        code, out = VoIPAppz::Docker.exec(sqlite_container, command)
        if verbose
          out.each_line do |l|
            next if l.starts_with?("sqlite_query:") || l.strip.empty?
            puts "    #{VoIPAppz::Colors.dim(l)}"
          end
        end
        {code, out}
      end

      # Current address rows via `kamctl address show` (id|grp|ip|mask|port|tag).
      def self.kamctl_address_rows : Array(NamedTuple(id: Int32, grp: Int32, ip: String, mask: Int32, port: Int32, tag: String))
        _, out = kamctl(["address", "show"])
        rows = [] of NamedTuple(id: Int32, grp: Int32, ip: String, mask: Int32, port: Int32, tag: String)
        out.each_line do |line|
          parts = line.strip.split("|")
          next unless parts.size >= 6
          id = parts[0].to_i?
          grp = parts[1].to_i?
          next unless id && grp
          rows << {id: id, grp: grp, ip: parts[2], mask: (parts[3].to_i? || 32), port: (parts[4].to_i? || 0), tag: parts[5]}
        end
        rows
      end

      # Current dispatcher rows via `kamctl dispatcher show`
      # (id|setid|destination|flags|priority|attrs|description). Non-data lines
      # (header, kamctl's "sqlite_query:" echo) are skipped by the int parse.
      def self.kamctl_dispatcher_rows : Array(NamedTuple(id: Int32, setid: Int32, destination: String, flags: Int32, priority: Int32, attrs: String, description: String))
        _, out = kamctl(["dispatcher", "show"])
        rows = [] of NamedTuple(id: Int32, setid: Int32, destination: String, flags: Int32, priority: Int32, attrs: String, description: String)
        out.each_line do |line|
          parts = line.strip.split("|")
          next unless parts.size >= 7
          id = parts[0].to_i?
          setid = parts[1].to_i?
          next unless id && setid
          rows << {id: id, setid: setid, destination: parts[2],
                   flags: (parts[3].to_i? || 0), priority: (parts[4].to_i? || 0),
                   attrs: parts[5], description: parts[6]}
        end
        rows
      end

      def self.load_config : VoIPAppz::DeployConfig
        path = ENV.fetch("VA_CONFIG_PATH", VoIPAppz::VaConfig.yaml_path(VoIPAppz::Docker.project_dir))
        unless File.exists?(path)
          STDERR.puts VoIPAppz::Colors.red("Missing #{path} — run `voipappz setup` first.")
          exit 1
        end
        VoIPAppz::DeployConfig.load(path)
      end

      def self.sql_quote(s : String) : String
        "'" + s.gsub("'", "''") + "'"
      end

      def self.managed?(description : String) : Bool
        description.starts_with?(MANAGED_PREFIX)
      end

      # IPv4/CIDR validation lives in the pure (testable) VoIPAppz::NetValidation
      # helper; delegate so call sites can keep using DBHelper.parse_cidr.
      def self.parse_cidr(input : String, default_mask : Int32) : {String, Int32}?
        VoIPAppz::NetValidation.parse_cidr(input, default_mask)
      end

      # Run an arbitrary command in a THROWAWAY container from the kamailio image
      # (`docker compose run --rm`), NOT the long-running service — overriding the
      # entrypoint to `sh` so kamailio itself never starts. The DB is the
      # bind-mounted ./data/kamailio, so schema work here does NOT depend on a
      # running kamailio (works while it's up, crash-looping, or never started).
      def self.in_throwaway(inner : String) : {Int32, String}
        io = IO::Memory.new
        status = Process.run("docker",
          ["compose", "run", "--rm", "--no-deps", "-T", "--entrypoint", "sh", "kamailio-egress", "-c", inner],
          output: io, error: io)
        {status.exit_code, io.to_s}
      end

      # Create the FULL standard schema with kamailio's own `kamdbctl create`
      # (the "create all the tables" command). The image's kamctlrc doesn't set
      # DBENGINE, so we pass it (+ the bind-mounted SQLite DB path) explicitly;
      # INSTALL_* + `yes` make it non-interactive. One-shot path for a fresh DB.
      def self.kamdbctl_create : {Int32, String}
        in_throwaway("export DBENGINE=SQLITE DBNAME=#{CONTAINER_DB_PATH} " \
                     "INSTALL_EXTRA_TABLES=no INSTALL_PRESENCE_TABLES=no " \
                     "INSTALL_DBUID_TABLES=no INSTALL_SERWEB_TABLES=no; " \
                     "yes | kamdbctl create #{CONTAINER_DB_PATH}")
      end

      # True if the table exists. A missing DB file (kamailio never booted) means
      # no tables — return false rather than erroring, so `db init` can create the
      # schema from scratch without a running container.
      def self.table_exists?(table : String) : Bool
        path = VoIPAppz::Docker.local_exec? ? CONTAINER_DB_PATH : SQLITE_DB_PATH
        return false unless File.exists?(path)
        read_sql("SELECT name FROM sqlite_master WHERE type='table' AND name='#{table}';").strip == table
      end
    end

    # Kamailio SQLite schema init/migration — kamailio best practice (`kamdbctl`).
    #
    # `db init` creates the schema WITHOUT a running kamailio: it runs in a
    # throwaway container from the kamailio image against the bind-mounted DB.
    #   * Fresh DB  -> `kamdbctl create` (the canonical "create all tables"
    #     command — full standard schema, incl. dialog/dialog_vars).
    #   * Existing DB -> read-only validation. The CLI never executes SQL text
    #     against the DB; an incomplete DB is rebuilt by moving it aside and
    #     re-running init (kamdbctl), then re-seeding with `sbc egress sync`.
    class DbGroup < Admiral::Command
      define_help description: "Kamailio DB schema: init/migrate the SQLite tables"

      {% unless flag?(:node_runtime) %}
        register_sub_command init, type: Init
      {% end %}
      register_sub_command status, type: Status

      def run
        puts help
      end

      # module schema-file stem => representative table that proves it's loaded.
      # Ordered: `standard` (the `version` table) FIRST — every other schema does
      # `INSERT INTO version (...)`, so on a from-scratch DB it must exist first.
      MODULES = [
        {"standard", "version"},
        {"dispatcher", "dispatcher"},
        {"permissions", "address"},
        {"domain", "domain"},
        {"usrloc", "location"},
        {"siptrace", "sip_trace"},
        {"dialog", "dialog"},
        # auth_db -> `subscriber`: the SIP credential store FreeSWITCH auths
        # against (via node) and `voipappz sbc egress subscriber` manages. Not in the
        # image's first-boot bootstrap, so the CLI must create it like the rest.
        {"auth_db", "subscriber"},
      ]

      class Init < Admiral::Command
        define_help description: "Initialize a fresh Kamailio database through kamdbctl"

        def run
          puts VoIPAppz::Colors.bold("Kamailio schema init (SQLite)")
          puts VoIPAppz::Colors.dim("  host DB:      #{File.expand_path(DBHelper::SQLITE_DB_PATH)}")
          puts VoIPAppz::Colors.dim("  container DB: #{DBHelper::CONTAINER_DB_PATH}  (via ./data/kamailio bind mount)")
          puts ""

          # Fresh DB (no `version` table) → one-shot Kamailio-owned schema
          # creation. No SQL text is executed by the CLI.
          if !DBHelper.table_exists?("version")
            puts VoIPAppz::Colors.dim("fresh DB — kamdbctl create (full standard schema)")
            code, res = DBHelper.kamdbctl_create
            res.strip.lines.last(6).each { |l| puts "  #{VoIPAppz::Colors.dim(l)}" }
            if code == 0
              puts "  #{VoIPAppz::Colors.green("kamdbctl create ok")}"
            else
              STDERR.puts VoIPAppz::Colors.red("kamdbctl create failed (exit #{code})")
              exit(code == 0 ? 1 : code)
            end
            puts ""
          end

          missing = DbGroup::MODULES.reject { |_, table| DBHelper.table_exists?(table) }
          DbGroup::MODULES.each do |stem, table|
            state = missing.any? { |_, missing_table| missing_table == table } ?
              VoIPAppz::Colors.red("missing") : VoIPAppz::Colors.green("ok")
            puts "  #{state} #{table} (#{stem})"
          end
          unless missing.empty?
            STDERR.puts ""
            STDERR.puts VoIPAppz::Colors.red(
              "Existing Kamailio DB is incomplete; refusing direct SQL migration.")
            STDERR.puts VoIPAppz::Colors.dim(
              "Recover kamailio-natively: back up ./data/kamailio, move the DB aside, and re-run " \
              "`voipappz sbc egress db init` (kamdbctl create builds the full schema), then `voipappz sbc egress sync`.")
            STDERR.puts VoIPAppz::Colors.dim(
              "Missing: #{missing.map(&.[1]).join(", ")}")
            exit 1
          end
          puts ""
          # Verify the DB actually landed on the HOST. If not, the kamailio
          # service isn't bind-mounting ./data/kamailio -> /var/lib/kamailio, so
          # the throwaway container wrote it into its own ephemeral FS and --rm
          # discarded it. That's the #1 cause of "created the schema but kamailio
          # still can't open the DB".
          host_db = File.expand_path(DBHelper::SQLITE_DB_PATH)
          if File.exists?(DBHelper::SQLITE_DB_PATH)
            puts VoIPAppz::Colors.green("Schema init complete -> #{host_db}")
            puts VoIPAppz::Colors.dim("Restart kamailio if db_mode changed, then `voipappz sbc egress sync`.")
          else
            puts VoIPAppz::Colors.red("WARNING: #{host_db} does NOT exist after init.")
            puts VoIPAppz::Colors.yellow("The kamailio service is not bind-mounting ./data/kamailio -> /var/lib/kamailio,")
            puts VoIPAppz::Colors.yellow("so the DB was generated inside the throwaway container and discarded (--rm).")
            puts VoIPAppz::Colors.yellow("Fix: add to the kamailio service volumes in docker-compose.yaml:")
            puts VoIPAppz::Colors.yellow("       - ./data/kamailio:/var/lib/kamailio")
            puts VoIPAppz::Colors.yellow("then re-run `voipappz sbc egress db init`.")
          end
        end
      end

      class Status < Admiral::Command
        define_help description: "Show which kamailio tables exist vs. expected"

        def run
          puts VoIPAppz::Colors.bold("Kamailio schema status (SQLite)")
          puts ""
          DbGroup::MODULES.each do |stem, table|
            if DBHelper.table_exists?(table)
              puts "  #{VoIPAppz::Colors.green("ok")}      #{table.ljust(12)} (#{stem})"
            else
              puts "  #{VoIPAppz::Colors.red("missing")} #{table.ljust(12)} (#{stem}) — run `voipappz sbc egress db init`"
            end
          end
        end
      end
    end

    class Sync < Admiral::Command
      define_help description: "Insert missing rows from config/va.yaml; reload kamailio"

      def run
        config = DBHelper.load_config
        c = DBHelper.container

        puts VoIPAppz::Colors.bold("Syncing #{c} from config/va.yaml")
        puts ""

        # The two boxes do NOT store the same way, and seeding one does not seed
        # the other — syncing only the egress is what left a fresh app node's
        # ingress with an empty dispatcher, 404-ing every call. Each has its own
        # command now, so run both on a combined node.
        if VoIPAppz::Docker.ingress?(c)
          # No database: the whole sync is render from va.yaml, write, reload.
          # SQL would fail here — db_sqlite is not even loaded on the ingress.
          sync_ingress_list(config, c)
        else
          unless sync_domain(config) && sync_dispatcher(config)
            STDERR.puts VoIPAppz::Colors.red("Kamailio control synchronization failed; modules were not reloaded.")
            exit 1
          end
          unless sync_address(config)
            STDERR.puts VoIPAppz::Colors.red("Provider address sync failed; Kamailio was not reloaded.")
            exit 1
          end
          puts VoIPAppz::Colors.dim("  reloading modules:")
          unless DBHelper.reload_all
            STDERR.puts VoIPAppz::Colors.red("One or more Kamailio modules failed to reload.")
            exit 1
          end
        end

        puts ""
        puts VoIPAppz::Colors.green("Sync complete (#{c}).")
      end

      # INGRESS: render config/kamailio/ingress/dispatcher.list from va.yaml and reload
      # it in place. The file is bind-mounted into the container, so writing it
      # on the host IS writing it in the container — no docker exec, no SQL.
      private def sync_ingress_list(config : VoIPAppz::DeployConfig, container : String) : Nil
        rows = VoIPAppz::DispatcherList.entries(config)
        path = VoIPAppz::DispatcherList.write(rows)

        if rows.empty?
          puts "  #{VoIPAppz::Colors.yellow("dispatcher")} #{path} written EMPTY — no nodes with role=switch and no gateways in config/va.yaml"
          puts "  #{VoIPAppz::Colors.dim("           ")} the ingress will 404 every call until this is populated (fail-closed, on purpose)"
        else
          rows.each do |e|
            tag = case e.setid
                  when VoIPAppz::DispatcherList::SET_INGRESS  then "INGRESS"
                  when VoIPAppz::DispatcherList::SET_EGRESS   then "EGRESS"
                  when VoIPAppz::DispatcherList::SET_CARRIERS then "CARRIER-SRC"
                  else                                             "set#{e.setid}"
                  end
            puts "  #{VoIPAppz::Colors.green("dispatcher")} set=#{e.setid}/#{tag} #{e.destination} #{VoIPAppz::Colors.dim(e.description)}"
          end
          puts "  #{VoIPAppz::Colors.dim("dispatcher")} #{rows.size} row(s) → #{path}"
        end

        # No permissions/domain reload here: neither module is loaded on the
        # ingress. Carrier identification is dispatcher set 100, so this one
        # reload covers everything the box knows.
        puts VoIPAppz::Colors.dim("  reloading modules:")
        ok = DBHelper.reload_one("dispatcher.reload")
        # A write nobody loaded is not a sync. Exit non-zero rather than print
        # "Sync complete" over a box still routing from the previous list.
        unless ok
          STDERR.puts VoIPAppz::Colors.red("  the ingress did not reload — it is still routing from its previous list")
          STDERR.puts VoIPAppz::Colors.dim("  retry, or reload by hand: docker exec #{container} kamcmd dispatcher.reload")
          exit 1
        end
      end

      private def sync_domain(config : VoIPAppz::DeployConfig) : Bool
        domain = config.organization.domain
        if domain.empty?
          puts "  #{VoIPAppz::Colors.dim("domain")}     skipped (organization.domain empty)"
          return true
        end

        code, out = DBHelper.kamctl(["domain", "add", domain], verbose: true)
        if code == 0 && !out.downcase.includes?("error")
          if out.includes?("already in")
            puts "  #{VoIPAppz::Colors.dim("domain")}     #{domain} (already present via kamctl)"
          else
            puts "  #{VoIPAppz::Colors.green("domain")}     #{domain} (added via kamctl)"
            # kamctl domain add writes no `did` column. The cfg compensates by
            # assigning $avp(did) = FS_DISPATCHER_SET after lookup_domain — but
            # only a kamailio RUNNING that cfg does; domain.reload does not load
            # cfg changes, so an egress started before the FS_DISPATCHER_SET
            # change routes this domain nowhere until it is restarted.
            puts "  #{VoIPAppz::Colors.yellow("note")}       new domain rows carry no did — " \
                 "va-egress must run the current kamailio.cfg (restart it if it predates FS_DISPATCHER_SET)"
          end
          true
        else
          STDERR.puts VoIPAppz::Colors.red("  domain      kamctl add failed: #{out.strip}")
          false
        end
      end

      private def sync_dispatcher(config : VoIPAppz::DeployConfig) : Bool
        targets = VoIPAppz::DispatcherList.entries(config).select do |entry|
          {DBHelper::ID_INGRESS, DBHelper::ID_EGRESS}.includes?(entry.setid)
        end

        # An empty target list is far more likely a degenerate YAML (API-side
        # regression, node briefly re-typed, partial rollout) than an operator
        # decommissioning FreeSWITCH. Wiping sets 1/2 here would break every
        # REGISTER/INVITE at ds_select_domain — skip and keep current routing.
        if targets.empty?
          puts "  #{VoIPAppz::Colors.yellow("dispatcher")} skipped — YAML yields no FreeSWITCH destinations; keeping current routing"
          return true
        end

        wanted = targets.to_h { |entry| { {entry.setid, entry.destination}, entry } }
        kept = Set({Int32, String}).new

        DBHelper.kamctl_dispatcher_rows.each do |row|
          key = {row[:setid], row[:destination]}
          target = wanted[key]?
          exact = target && row[:flags] == target.flags && row[:priority] == 0 &&
            row[:attrs] == target.attrs && row[:description] == target.description && !kept.includes?(key)

          if exact
            kept << key
            next
          end
          next unless DBHelper.managed?(row[:description]) || target

          code, out = DBHelper.kamctl(["dispatcher", "rm", row[:id].to_s], verbose: true)
          unless code == 0 && !out.downcase.includes?("error")
            STDERR.puts VoIPAppz::Colors.red("  dispatcher  kamctl rm failed for id=#{row[:id]}: #{out.strip}")
            return false
          end
          puts "  #{VoIPAppz::Colors.yellow("dispatcher")} pruned id=#{row[:id]} set=#{row[:setid]} #{row[:destination]}"
        end

        targets.each do |target|
          key = {target.setid, target.destination}
          if kept.includes?(key)
            puts "  #{VoIPAppz::Colors.dim("dispatcher")} set=#{target.setid} #{target.destination} (ok)"
            next
          end

          args = ["dispatcher", "add", target.setid.to_s, target.destination,
                  target.flags.to_s, "0", target.attrs, target.description]
          code, out = DBHelper.kamctl(args, verbose: true)
          unless code == 0 && !out.downcase.includes?("error")
            STDERR.puts VoIPAppz::Colors.red("  dispatcher  kamctl add failed for #{target.destination}: #{out.strip}")
            return false
          end
          puts "  #{VoIPAppz::Colors.green("dispatcher")} set=#{target.setid} #{target.destination} (added via kamctl)"
        end

        puts "  #{VoIPAppz::Colors.dim("dispatcher")} authoritative YAML snapshot is empty" if targets.empty?
        true
      end

      private def sync_address(config : VoIPAppz::DeployConfig) : Bool
        # Carrier/provider IPs from va.yaml sip_interfaces[].gateways populate the
        # permissions `address` table in group 2 (inbound peers), so the KEMI
        # allow_address("2", $si) gate accepts their INVITEs. Group 2 is an
        # authoritative snapshot with ONE carve-out: rows tagged manual:* (the
        # `sbc egress address add` escape hatch) belong to the operator and are
        # preserved — an emergency carrier added mid-incident must survive the
        # next sync/NATS-triggered reconciliation. All other group-2 rows are
        # owned by the YAML and pruned when absent from it.
        # Each gateway entry carries the full inbound-peer data as a string both
        # the CLI and the node parse (gateways stays Array(String)):
        #   "ip"                → /32, default managed tag
        #   "ip/mask"           → CIDR (carrier range), default managed tag
        #   "ip/mask|<tag>"     → CIDR + custom tag (e.g. the carrier/gateway UUID).
        # The tag is what kamailio returns on allow_address match ($avp(i:707) →
        # X-VA-Gateway), identifying which carrier the call came from.
        desired = [] of VoIPAppz::AddressSnapshot::Row
        config.sip_interfaces.each do |si|
          default_tag = "#{DBHelper::MANAGED_PREFIX}#{si.name}/gw"
          si.gateways.each do |gw|
            parsed = DBHelper.parse_cidr(gw.address, 32)
            unless parsed
              STDERR.puts VoIPAppz::Colors.red("  address     invalid provider CIDR '#{gw.address}'")
              return false
            end
            ip, mask = parsed
            tag = gw.tag.empty? ? default_tag : gw.tag
            desired << VoIPAppz::AddressSnapshot::Row.new(
              DBHelper::ID_EGRESS, ip, mask, gw.port, tag)
          end
        end

        desired_ips = desired.map(&.ip).to_set
        existing = DBHelper.kamctl_address_rows.compact_map do |row|
          # Operator-owned rows stay out of the plan entirely — unless the YAML
          # now claims the same IP, in which case the YAML row must replace the
          # manual one (two grp+ip rows would otherwise accumulate).
          if row[:tag].starts_with?(DBHelper::MANUAL_PREFIX) && !desired_ips.includes?(row[:ip])
            if row[:grp] == DBHelper::ID_EGRESS
              puts "  #{VoIPAppz::Colors.dim("address")}    grp=#{row[:grp]} #{row[:ip]}/#{row[:mask]} (operator row, preserved)"
            end
            next
          end
          VoIPAppz::AddressSnapshot::Row.new(
            row[:grp], row[:ip], row[:mask], row[:port], row[:tag])
        end
        plan = VoIPAppz::AddressSnapshot.plan(existing, desired, DBHelper::ID_EGRESS)

        plan.remove.each do |row|
          code, out = DBHelper.kamctl(["address", "rm", row[:grp].to_s, row[:ip]], verbose: true)
          unless code == 0
            STDERR.puts VoIPAppz::Colors.red("  address     failed to remove #{row[:ip]}: #{out.strip}")
            return false
          end
          puts "  #{VoIPAppz::Colors.yellow("address")}    pruned grp=#{row[:grp]} #{row[:ip]}"
        end

        plan.add.each do |row|
          code, out = DBHelper.kamctl([
            "address", "add", row.grp.to_s, row.ip, row.mask.to_s,
            row.port.to_s, row.tag
          ], verbose: true)
          if code == 0
            puts "  #{VoIPAppz::Colors.green("address")}    grp=#{row.grp} #{row.ip}/#{row.mask} (added, tag=#{row.tag})"
          else
            STDERR.puts VoIPAppz::Colors.red("  address     failed to add #{row.ip}/#{row.mask}: #{out.strip}")
            return false
          end
        end

        plan.keep.each do |row|
          puts "  #{VoIPAppz::Colors.dim("address")}    grp=#{row.grp} #{row.ip}/#{row.mask} (ok, tag=#{row.tag})"
        end

        if desired.empty?
          puts "  #{VoIPAppz::Colors.dim("address")}    authoritative gateway snapshot is empty"
        end
        true
      rescue ex : ArgumentError
        STDERR.puts VoIPAppz::Colors.red("  address     invalid provider snapshot: #{ex.message}")
        false
      end
    end

    class Reload < Admiral::Command
      define_help description: "Reload kamailio modules (dispatcher, permissions, domain)"

      def run
        puts VoIPAppz::Colors.bold("Reloading Kamailio modules via kamcmd:")
        DBHelper.reload_all
      end
    end

    class Status < Admiral::Command
      define_help description: "Show row counts for dispatcher, address, domain"

      def run
        # SQLite-portable: SUM(CASE) instead of FILTER, no ::text casts.
        sql = <<-SQL
          SELECT 'dispatcher', COUNT(*), SUM(CASE WHEN description LIKE 'managed:yaml/%' THEN 1 ELSE 0 END) FROM dispatcher
          UNION ALL
          SELECT 'address',    COUNT(*), SUM(CASE WHEN tag LIKE 'managed:yaml/%' THEN 1 ELSE 0 END)         FROM address
          UNION ALL
          SELECT 'domain',     COUNT(*), COUNT(*)                                                            FROM domain
          ORDER BY 1;
        SQL
        out = DBHelper.read_sql(sql)
        puts VoIPAppz::Colors.bold("Kamailio data tables (sqlite):")
        out.each_line do |line|
          parts = line.split("|")
          next if parts.size < 3
          tbl, total, managed = parts[0], parts[1], parts[2]
          color = total == "0" ? VoIPAppz::Colors.yellow(total) : VoIPAppz::Colors.green(total)
          puts "  #{tbl.ljust(12)} #{color} rows  (#{managed} managed by yaml)"
        end
      end
    end

    class List < Admiral::Command
      define_help description: "Print rows from dispatcher / address / domain"

      define_argument table : String,
        description: "Table: dispatcher, address, domain, or all (default)",
        default: "all"

      def run
        tbl = (arguments.table || "all").downcase
        valid = {"dispatcher", "address", "domain", "all"}
        unless valid.includes?(tbl)
          STDERR.puts VoIPAppz::Colors.red("Unknown table: #{tbl}")
          STDERR.puts "Valid: #{valid.join(", ")}"
          exit 1
        end

        list_dispatcher if tbl == "dispatcher" || tbl == "all"
        list_address if tbl == "address" || tbl == "all"
        list_domain if tbl == "domain" || tbl == "all"
      end

      private def src_marker(description : String) : String
        DBHelper.managed?(description) ? "[yaml]  " : "[manual]"
      end

      private def list_dispatcher : Nil
        puts ""
        puts VoIPAppz::Colors.bold("dispatcher")
        rows_data = DBHelper.kamctl_dispatcher_rows
        if rows_data.empty?
          puts "  #{VoIPAppz::Colors.dim("(no rows)")}"
          return
        end
        cols = [
          VoIPAppz::Table::Column.new("id", 4),
          VoIPAppz::Table::Column.new("setid", 6),
          VoIPAppz::Table::Column.new("destination", 32),
          VoIPAppz::Table::Column.new("attrs", 18),
          VoIPAppz::Table::Column.new("src", 9),
          VoIPAppz::Table::Column.new("description", 30),
        ]
        rows = rows_data.map do |r|
          [r[:id].to_s, r[:setid].to_s, r[:destination], r[:attrs], src_marker(r[:description]), r[:description]]
        end
        puts VoIPAppz::Table.render(cols, rows)
      end

      private def list_address : Nil
        puts ""
        puts VoIPAppz::Colors.bold("address")
        rows_data = DBHelper.kamctl_address_rows
        if rows_data.empty?
          puts "  #{VoIPAppz::Colors.dim("(no rows)")}"
          return
        end
        cols = [
          VoIPAppz::Table::Column.new("id", 4),
          VoIPAppz::Table::Column.new("grp", 4),
          VoIPAppz::Table::Column.new("ip_addr", 18),
          VoIPAppz::Table::Column.new("mask", 5),
          VoIPAppz::Table::Column.new("port", 6),
          VoIPAppz::Table::Column.new("src", 9),
          VoIPAppz::Table::Column.new("tag", 24),
        ]
        rows = rows_data.map do |r|
          [r[:id].to_s, r[:grp].to_s, r[:ip], r[:mask].to_s, r[:port].to_s, src_marker(r[:tag]), r[:tag]]
        end
        puts VoIPAppz::Table.render(cols, rows)
      end

      private def list_domain : Nil
        puts ""
        puts VoIPAppz::Colors.bold("domain")
        out = DBHelper.read_sql(
          "SELECT id, domain, COALESCE(did,''), last_modified FROM domain ORDER BY id;"
        )
        if out.strip.empty?
          puts "  #{VoIPAppz::Colors.dim("(no rows)")}"
          return
        end
        cols = [
          VoIPAppz::Table::Column.new("id", 4),
          VoIPAppz::Table::Column.new("domain", 32),
          VoIPAppz::Table::Column.new("did", 8),
          VoIPAppz::Table::Column.new("last_modified", 24),
        ]
        rows = out.lines.map { |l| l.split("|", 4) }
        puts VoIPAppz::Table.render(cols, rows)
      end
    end

    # Per-table groups, each with an `add` subcommand for manual entries.
    # Manual rows have a non-managed:yaml/* description/tag, so `sync`'s
    # `WHERE NOT EXISTS` check leaves them alone, and `list` shows [manual].

    class DispatcherGroup < Admiral::Command
      define_help description: "Dispatcher operations"
      register_sub_command add, type: Add
      register_sub_command rm, type: Rm
      register_sub_command status, type: Status
      def run; puts help; end

      class Rm < Admiral::Command
        define_help description: "Remove a dispatcher destination by setid+destination; reloads kamailio"
        define_flag setid : Int32, description: "Set ID the destination belongs to", required: true
        define_flag destination : String, description: "e.g. sip:178.22.10.20:5060", required: true
        define_flag no_reload : Bool, description: "Skip kamailio reload after delete", default: false

        def run
          dest = flags.destination
          dest = "sip:#{dest}" unless dest.starts_with?("sip:")

          # setid+destination, not a bare row id: ids are internal and shift
          # across syncs; the pair is what the operator actually knows.
          rows = DBHelper.kamctl_dispatcher_rows.select do |row|
            row[:setid] == flags.setid && row[:destination] == dest
          end
          if rows.empty?
            STDERR.puts VoIPAppz::Colors.red("no dispatcher row matches setid=#{flags.setid} #{dest}")
            exit 1
          end

          rows.each do |row|
            code, out = DBHelper.kamctl(["dispatcher", "rm", row[:id].to_s], verbose: true)
            unless code == 0 && !out.downcase.includes?("error")
              STDERR.puts VoIPAppz::Colors.red("dispatcher rm failed for id=#{row[:id]}: #{out.strip}")
              exit 1
            end
            puts VoIPAppz::Colors.green("dispatcher removed: id=#{row[:id]} setid=#{flags.setid} #{dest}")
          end
          unless flags.no_reload || DBHelper.reload_one("dispatcher.reload")
            STDERR.puts VoIPAppz::Colors.red("dispatcher was removed, but Kamailio reload failed")
            exit 1
          end
        end
      end

      # Live dispatcher state from kamailio JSON-RPC (dispatcher.list).
      # Flags: A=Active I=Inactive P=Probing D=Disabled T=Trying
      # "AP" = good; "IP" = FS is down/unreachable.
      class Status < Admiral::Command
        define_help description: "Show live dispatcher destination state (active/inactive) via JSON-RPC"

        def run
          # Query live dispatcher state via in-container kamcmd (the JSON-RPC
          # HTTP transport isn't wired up on the KEMI node-lite config).
          # `listing`, not `out`: `out` is a Crystal keyword (C-binding output
          # parameters) and parses as an assignment target but not as a bare
          # argument, so passing it to a method fails with "unexpected token".
          code, listing = VoIPAppz::Docker.exec(DBHelper.container, ["kamcmd", "dispatcher.list"])
          if code != 0 || listing.downcase.includes?("no destination")
            if listing.downcase.includes?("no destination")
              puts VoIPAppz::Colors.yellow("dispatcher has no destinations — run: voipappz sbc egress sync")
              return
            end
            STDERR.puts VoIPAppz::Colors.red("kamcmd dispatcher.list failed: #{listing.strip}")
            STDERR.puts VoIPAppz::Colors.dim("  Is kamailio running? Try: voipappz up -p voip")
            exit 1
          end

          # ONE parser and ONE flag decode, shared with `sbc ingress list`
          # (VoIPAppz::DispatcherList). This used to hand-roll both, and its
          # decode had no concept of set 100 being source-only — so a carrier
          # source, which is DISABLED on purpose, rendered as a bare "DX" and
          # read as a fault. That is the same bug fixed for the ingress; fixing
          # it in one place is the reason the parser moved to a helper.
          targets = VoIPAppz::DispatcherList.parse_kamcmd(listing)
          if targets.empty?
            puts VoIPAppz::Colors.yellow("dispatcher returned no destinations — run: voipappz sbc egress sync")
            return
          end

          rows = targets.map do |t|
            state = case
                    when t.source_only? then VoIPAppz::Colors.dim(t.state)
                    when t.usable?      then VoIPAppz::Colors.green(t.state)
                    else                     VoIPAppz::Colors.red(t.state)
                    end
            [t.setid.to_s, t.uri, t.flags, state, t.note]
          end

          puts VoIPAppz::Colors.bold("Dispatcher live state (via kamcmd)")
          puts ""
          puts VoIPAppz::Table.render([
            VoIPAppz::Table::Column.new("set", 4),
            VoIPAppz::Table::Column.new("destination", 32),
            VoIPAppz::Table::Column.new("flags", 7),
            VoIPAppz::Table::Column.new("state", 10),
            VoIPAppz::Table::Column.new("", 42),
          ], rows)

          # The same verdict `sbc ingress list` reaches, from the same helper —
          # this command rendered the table and stopped, so it could show every
          # target DOWN and exit 0.
          case VoIPAppz::DispatcherList.routing(targets)
          when .down?
            puts VoIPAppz::Colors.red("  Every routing target is down — calls will 404.")
            exit VoIPAppz::DispatcherList::EXIT_DOWN
          when .degraded?
            puts VoIPAppz::Colors.yellow("  Some routing targets are down.")
          end
        end
      end

      class Add < Admiral::Command
        define_help description: "Add a dispatcher destination (sip: URI); reloads kamailio"
        define_flag setid : Int32, description: "Set ID (1=ingress, 2=egress, custom)", required: true
        define_flag destination : String, description: "e.g. sip:178.22.10.20:5060", required: true
        define_flag attrs : String, description: "attrs (typically external IP for SDP)", default: ""
        define_flag description : String, description: "Free-text label", default: ""
        define_flag priority : Int32, description: "Priority within set", default: 0
        define_flag flags : Int32, description: "Dispatcher flags", default: 0
        define_flag no_reload : Bool, description: "Skip kamailio reload after insert", default: false

        def run
          # Native kamailio path: `kamctl dispatcher add` runs INSIDE the kamailio
          # container (as root, against the module's own DB) — never host sqlite3.
          # kamctl signature: dispatcher add <setid> <dest> [flags] [priority] [attrs] [description]
          dest = flags.destination
          dest = "sip:#{dest}" unless dest.starts_with?("sip:")

          if flags.setid < 1
            STDERR.puts VoIPAppz::Colors.red("dispatcher set ID must be greater than zero")
            exit 1
          end

          existing = DBHelper.kamctl_dispatcher_rows.find do |row|
            row[:setid] == flags.setid && row[:destination] == dest
          end
          if existing
            puts VoIPAppz::Colors.yellow(
              "dispatcher already exists: id=#{existing[:id]} setid=#{flags.setid} #{dest}")
            return
          end

          args = ["dispatcher", "add", flags.setid.to_s, dest, flags.flags.to_s, flags.priority.to_s]
          # attrs (5th positional) / description (6th) are optional & may contain
          # spaces — single-quote them. description needs attrs present as its slot.
          if !flags.attrs.empty? || !flags.description.empty?
            args << flags.attrs
            args << flags.description unless flags.description.empty?
          end

          code, out = DBHelper.kamctl(args, verbose: true)
          if code == 0 && !out.downcase.includes?("error")
            puts VoIPAppz::Colors.green("dispatcher added: setid=#{flags.setid} #{dest}")
          else
            STDERR.puts VoIPAppz::Colors.red("dispatcher add failed: #{out.strip}")
            exit 1
          end
          unless flags.no_reload || DBHelper.reload_one("dispatcher.reload")
            STDERR.puts VoIPAppz::Colors.red("dispatcher was added, but Kamailio reload failed")
            exit 1
          end
        end
      end
    end

    class AddressGroup < Admiral::Command
      define_help description: "Address (permissions ACL) operations"
      register_sub_command add, type: Add
      register_sub_command remove, type: Remove
      def run; puts help; end

      class Remove < Admiral::Command
        define_help description: "Remove address row(s) by grp+ip (IPv4 or CIDR); reloads kamailio"
        define_flag grp : Int32, description: "Permissions group", required: true
        define_flag ip : String, description: "IPv4 or CIDR to remove (all entries for grp+ip)", required: true
        define_flag no_reload : Bool, description: "Skip kamailio reload after delete", default: false

        def run
          # Accept CIDR for symmetry with `add`; kamctl rm matches on the IP only.
          parsed = DBHelper.parse_cidr(flags.ip, 32)
          unless parsed
            STDERR.puts VoIPAppz::Colors.red("invalid address '#{flags.ip}' — expected IPv4 or CIDR (e.g. 192.168.0.0/16)")
            exit 1
          end
          ip, _ = parsed

          # kamctl address rm <grp> <ipaddr> — kamailio-native, no direct SQL.
          code, out = DBHelper.kamctl(["address", "rm", flags.grp.to_s, ip], verbose: true)
          if code == 0
            puts VoIPAppz::Colors.green("address removed via kamctl: grp=#{flags.grp} #{ip}")
          else
            STDERR.puts VoIPAppz::Colors.red("kamctl address rm failed (exit #{code}): #{out.strip}")
            exit 1
          end
          DBHelper.reload_one("permissions.addressReload") unless flags.no_reload
        end
      end

      class Add < Admiral::Command
        define_help description: "Add an address ACL row (--ip takes IPv4 or CIDR); reloads kamailio"
        define_flag grp : Int32, description: "Permissions group (e.g. 2 = inbound peers)", required: true
        define_flag ip : String, description: "IPv4 or CIDR (e.g. 185.240.140.10 or 192.168.0.0/16)", required: true
        define_flag mask : Int32, description: "Mask bits when --ip has no /N (32 = single IP)", default: 32
        define_flag port : Int32, description: "Port (0 = any)", default: 0
        define_flag tag : String, description: "Free-text tag (defaults to manual:cli; manual:* rows survive `sync`)", default: ""
        define_flag no_reload : Bool, description: "Skip kamailio reload after insert", default: false

        def run
          # Accept CIDR in --ip (a /N there wins over --mask); validate before any write.
          parsed = DBHelper.parse_cidr(flags.ip, flags.mask)
          unless parsed
            STDERR.puts VoIPAppz::Colors.red("invalid address '#{flags.ip}' — expected IPv4 or CIDR (e.g. 192.168.0.0/16), mask 0-32")
            STDERR.puts VoIPAppz::Colors.dim("  example: voipappz sbc egress address add --grp 2 --ip 192.168.0.0/16 --tag carrier")
            exit 1
          end
          ip, mask = parsed

          # Default into the manual: namespace — that is what marks the row as
          # operator-owned so the authoritative YAML sync preserves it. A custom
          # tag outside manual:* is allowed but will be pruned by the next sync.
          tag = flags.tag.empty? ? "#{DBHelper::MANUAL_PREFIX}cli" : flags.tag
          unless tag.starts_with?(DBHelper::MANUAL_PREFIX)
            puts VoIPAppz::Colors.yellow("tag '#{tag}' is outside #{DBHelper::MANUAL_PREFIX}* — the next `sync` will prune this row")
          end

          # kamctl address add <grp> <ipaddr> <mask> <port> <tag> — kamailio-native.
          # Skip if an identical grp+ip row already exists (kamctl add isn't idempotent).
          if DBHelper.kamctl_address_rows.any? { |r| r[:grp] == flags.grp && r[:ip] == ip && r[:mask] == mask }
            puts VoIPAppz::Colors.yellow("address row already exists (grp=#{flags.grp} ip=#{ip}/#{mask})")
            return
          end
          code, out = DBHelper.kamctl(
            ["address", "add", flags.grp.to_s, ip, mask.to_s, flags.port.to_s, tag],
            verbose: true)
          if code == 0
            puts VoIPAppz::Colors.green("address added via kamctl: grp=#{flags.grp} #{ip}/#{mask}:#{flags.port} tag='#{tag}'")
          else
            STDERR.puts VoIPAppz::Colors.red("kamctl address add failed (exit #{code}): #{out.strip}")
            exit 1
          end
          DBHelper.reload_one("permissions.addressReload") unless flags.no_reload
        end
      end
    end

    # SIP subscribers (auth users) — the LOCAL credential store in kamailio's
    # `subscriber` table. node OWNS the writes: the CLI sends a NATS command to
    # the node (subject node:<VA_NODE_UUID>:kamailio.command.sync — the same bus
    # EslExecutor uses for FreeSWITCH), and node computes ha1/ha1b + writes the
    # row. FreeSWITCH authenticates against that table via node's xml_curl
    # directory. The subscriber.domain MUST equal the SIP auth realm.
    class SubscriberGroup < Admiral::Command
      define_help description: "SIP subscriber (auth) users in the local kamailio DB (kamctl)"
      register_sub_command add, type: Add
      register_sub_command remove, type: Remove
      register_sub_command passwd, type: Passwd
      register_sub_command show, type: Show
      def run; puts help; end

      # Manage the local `subscriber` table via `kamctl add|rm|passwd <user@domain>`
      # in the kamailio container — kamctl computes ha1/ha1b (realm = the domain)
      # and FS authenticates against that table. DB only, no NATS/node round-trip.
      def self.run_kamctl(args : Array(String), ok_msg : String) : Nil
        code, out = DBHelper.kamctl(args, verbose: true)
        low = out.downcase
        # kamctl exits non-zero with an INFO/ERROR line for the idempotent
        # no-ops — treat those as benign, not a hard failure. The kamailio 5.6.2
        # binary this image ships words them:
        #   add, AOR present:      "** INFO: user 'x@d' already exists"
        #   rm/passwd, AOR absent: "** ERROR: non-existent user 'x@d'"
        # "non-existent" is the one that matters and was missing here, so
        # removing an already-absent subscriber exited 1 — the node side
        # (SubscriberAdmin.benign?) has always accepted it, and these two must
        # agree or the same kamctl reply means "done" on one path and "failed"
        # on the other. "does not exist"/"not exist" stay for other versions.
        if low.includes?("already exists") || low.includes?("non-existent") ||
           low.includes?("does not exist") || low.includes?("not exist")
          info = out.lines.find { |l| l.includes?(":") }
          puts VoIPAppz::Colors.yellow((info || out).strip)
          return
        end
        if code == 0 && !low.includes?("error")
          puts VoIPAppz::Colors.green(ok_msg)
        else
          STDERR.puts VoIPAppz::Colors.red("kamctl #{args.first} failed: #{out.strip}")
          exit 1
        end
      end

      class Add < Admiral::Command
        define_help description: "Add a SIP subscriber (kamctl computes ha1; FS auths against it)"
        define_flag user : String, description: "Username / extension", required: true
        define_flag domain : String, description: "SIP domain (= the auth realm)", required: true
        define_flag password : String, description: "SIP password", required: true

        def run
          aor = "#{flags.user}@#{flags.domain}"
          SubscriberGroup.run_kamctl(["add", aor, flags.password], "subscriber added: #{aor}")
        end
      end

      class Remove < Admiral::Command
        define_help description: "Remove a SIP subscriber"
        define_flag user : String, description: "Username / extension", required: true
        define_flag domain : String, description: "SIP domain", required: true

        def run
          aor = "#{flags.user}@#{flags.domain}"
          SubscriberGroup.run_kamctl(["rm", aor], "subscriber removed: #{aor}")
        end
      end

      class Passwd < Admiral::Command
        define_help description: "Change a subscriber's password (kamctl recomputes ha1)"
        define_flag user : String, description: "Username / extension", required: true
        define_flag domain : String, description: "SIP domain", required: true
        define_flag password : String, description: "New SIP password", required: true

        def run
          aor = "#{flags.user}@#{flags.domain}"
          SubscriberGroup.run_kamctl(["passwd", aor, flags.password], "password updated: #{aor}")
        end
      end

      class Show < Admiral::Command
        define_help description: "List SIP subscribers (username@domain; secrets not shown)"
        def run
          # No kamctl "list all" — read username/domain from the local DB (in-container).
          out = DBHelper.read_sql("SELECT username || '@' || domain FROM subscriber ORDER BY domain, username;").strip
          rows = out.lines.map(&.strip).reject(&.empty?)
          if rows.empty?
            puts VoIPAppz::Colors.dim("no subscribers — add one with `voipappz sbc egress subscriber add`")
            return
          end
          puts VoIPAppz::Colors.header("SIP subscribers (#{rows.size})")
          rows.each { |r| puts "  #{r}" }
        end
      end
    end

    class DomainGroup < Admiral::Command
      define_help description: "Domain operations"
      register_sub_command add, type: Add
      def run; puts help; end

      class Add < Admiral::Command
        define_help description: "Manually add a serving domain; reloads kamailio"
        define_flag domain : String, description: "Domain (FQDN)", required: true
        define_flag no_reload : Bool, description: "Skip kamailio reload after insert", default: false
        define_flag reload_address : Bool, description: "Also reload the address (permissions) table after the domain is added", default: false

        def run
          dom = flags.domain
          code, out = DBHelper.kamctl(["domain", "add", dom], verbose: true)
          if code != 0 || out.downcase.includes?("error")
            STDERR.puts VoIPAppz::Colors.red("kamctl domain add failed (exit #{code}): #{out.strip}")
            exit(code == 0 ? 1 : code)
          end
          if out.includes?("already in")
            puts VoIPAppz::Colors.yellow("domain already present: #{dom}")
          else
            puts VoIPAppz::Colors.green("domain added via kamctl: #{dom}")
          end
          return if flags.no_reload
          unless DBHelper.reload_one("domain.reload")
            STDERR.puts VoIPAppz::Colors.red("domain was added, but Kamailio reload failed")
            exit 1
          end
          if flags.reload_address && !DBHelper.reload_one("permissions.addressReload")
            STDERR.puts VoIPAppz::Colors.red("permissions reload failed")
            exit 1
          end
        end
      end
    end

    # Siptrace control: live on/off via kamcmd cfg.set_now_int (no restart),
    # status (current trace_on flag + DB row count), and query against the
    # sip_trace table. Mirrors the Ruby Kamailio::SipTrace.all pattern.
    class TraceGroup < Admiral::Command
      define_help description: "Siptrace control (on/off/status/query)"
      register_sub_command on, type: On
      register_sub_command off, type: Off
      register_sub_command status, type: Status
      register_sub_command query, type: Query
      def run; puts help; end

      private def self.set_trace_on(value : Int32) : Nil
        exit_code, stdout = VoIPAppz::Docker.exec(
          DBHelper.container,
          ["kamcmd", "cfg.set_now_int", "siptrace", "trace_on", value.to_s],
        )
        if exit_code == 0
          puts VoIPAppz::Colors.green("siptrace trace_on=#{value}") + " (live, no restart)"
        else
          STDERR.puts VoIPAppz::Colors.red("kamcmd failed: #{stdout}")
          exit exit_code
        end
      end

      def self.do_on : Nil; set_trace_on(1); end
      def self.do_off : Nil; set_trace_on(0); end

      class On < Admiral::Command
        define_help description: "Enable SIP tracing live (kamcmd cfg.set_now_int)"
        def run; TraceGroup.do_on; end
      end

      class Off < Admiral::Command
        define_help description: "Disable SIP tracing live (kamcmd cfg.set_now_int)"
        def run; TraceGroup.do_off; end
      end

      class Status < Admiral::Command
        define_help description: "Current trace_on flag + sip_trace row count"
        def run
          exit_code, stdout = VoIPAppz::Docker.exec(
            DBHelper.container,
            ["kamcmd", "cfg.get", "siptrace", "trace_on"],
          )
          flag = exit_code == 0 ? stdout.strip : "?"
          flag_label = flag == "1" ? VoIPAppz::Colors.green("ON") : VoIPAppz::Colors.yellow("OFF")
          puts "  trace_on:  #{flag_label} (raw=#{flag})"

          # SQLite-portable — no ::text casts (sqlite3 prints scalars as text).
          row = DBHelper.read_sql(
            "SELECT COUNT(*), COALESCE(MAX(time_stamp), '(none)') FROM sip_trace;"
          ).strip
          parts = row.split("|", 2)
          count = parts[0]? || "0"
          last  = parts[1]? || "(none)"
          puts "  rows:      #{count}"
          puts "  last_seen: #{last}"
        end
      end

      class Query < Admiral::Command
        define_help description: "Query recent sip_trace rows (DB)"
        define_flag hours : Int32, description: "Window in hours", default: 1
        define_flag method : String, description: "Method filter (INVITE, REGISTER, BYE, ...)", default: ""
        define_flag callid : String, description: "Filter by Call-ID", default: ""
        define_flag limit : Int32, description: "Max rows", default: 50
        define_flag show_body : Bool, description: "Include decoded message body", default: false

        def run
          # SQLite dialect — datetime() window, no ::text casts, and msg is
          # stored raw (no Postgres hex encoding to undo).
          where = ["time_stamp >= datetime('now', '-#{flags.hours} hours')"]
          where << "method = #{DBHelper.sql_quote(flags.method)}" unless flags.method.empty?
          where << "callid = #{DBHelper.sql_quote(flags.callid)}" unless flags.callid.empty?
          select_cols = "time_stamp, method, status, fromip, toip, callid"
          if flags.show_body
            select_cols += ", CAST(msg AS TEXT)"
          end
          sql = "SELECT #{select_cols} FROM sip_trace WHERE #{where.join(" AND ")} " \
                "ORDER BY time_stamp DESC LIMIT #{flags.limit};"
          out = DBHelper.read_sql(sql)
          if out.strip.empty?
            puts VoIPAppz::Colors.dim("(no traces match)")
            return
          end
          out.each_line do |line|
            parts = line.split("|")
            ts = parts[0]? || ""
            mtd = parts[1]? || ""
            status = parts[2]? || ""
            fip = parts[3]? || ""
            tip = parts[4]? || ""
            cid = parts[5]? || ""
            puts "#{VoIPAppz::Colors.dim(ts)} #{VoIPAppz::Colors.bold(mtd.ljust(8))} #{status.ljust(4)} #{fip} → #{tip}  #{VoIPAppz::Colors.dim(cid)}"
            if flags.show_body && parts[6]?
              puts "    " + parts[6].not_nil!.lines.first(20).join("\n    ")
              puts ""
            end
          end
        end
      end
    end


    # `voipappz trace hep` — control SIP capture via the HEP protocol.
    #
    # Wraps two concerns:
    #   1. Telling Kamailio to mirror every SIP message as HEP3 to a local
    #      collector (siptrace duplicate_uri + hep_mode_on). The first call
    #      patches kamailio.cfg and restarts the container; subsequent
    #      enable/disable cycles flip `trace_on` live via kamcmd (no restart).
    #   2. Running an in-process HEP3 collector that decodes packets and
    #      pretty-prints SIP traffic to the terminal — uses the vendored
    #      decoder under cli/src/helpers/hep.
    class HepGroup < Admiral::Command
      define_help description: "SIP capture via HEP (enable/disable + live UDP listener)"

      register_sub_command enable, type: Enable
      register_sub_command disable, type: Disable
      register_sub_command status, type: Status
      register_sub_command listen, type: Listen
      register_sub_command send, type: Send
      register_sub_command selftest, type: Selftest
      register_sub_command query, type: Query

      def run; puts help; end

      # Distinct capture id PER BOX: one collector receives both legs, and
      # without separate ids they are indistinguishable in the capture — which
      # is precisely the question capture exists to answer ("which kamailio
      # mangled this"). 111 ingress, 112 egress; 112 stays reserved.
      #
      # Only the INGRESS is patchable from here. The egress config is not in
      # this repo — it lives in va-crystal (ci/kamailio/kamailio.cfg) and is
      # BAKED INTO the node image, with nothing bind-mounted over it, so there
      # is no host-side file to edit and a restart would not pick one up.
      # Enabling the egress leg is a node-side operation (see
      # docs/architecture-boundaries.md: node operations go over NATS). Until
      # that exists, `enable` says so out loud rather than capturing one leg
      # and letting the other look like silence.
      CAPTURE_IDS = {
        "config/kamailio/ingress/kamailio.cfg" => 111, # ingress
      }
      # Derived, so the two cannot drift: every config with a capture id is a
      # config to patch, by definition. (CAPTURE_ID, a fallback for a path not
      # in the map, was unreachable for the same reason and is gone.)
      CFG_PATHS = CAPTURE_IDS.keys
      # The config the status readers below report on — the only one on disk.
      INGRESS_CFG      = "config/kamailio/ingress/kamailio.cfg"
      DEFAULT_HEP_ADDR = "127.0.0.1"
      DEFAULT_HEP_PORT = 9060

      # Patch every kamailio config present. Idempotent; returns true if ANY
      # changed (i.e. the operator needs to restart).
      def self.ensure_cfg_patched(addr : String, port : Int32) : Bool
        present = CFG_PATHS.select { |p| File.exists?(p) }
        if present.empty?
          STDERR.puts VoIPAppz::Colors.red("No kamailio config found (looked for #{CFG_PATHS.join(", ")}) — run from the project root")
          exit 1
        end
        present.map { |path| patch_one(path, addr, port) }.any?
      end

      private def self.patch_one(path : String, addr : String, port : Int32) : Bool
        capture_id = CAPTURE_IDS[path]
        content = File.read(path)

        duplicate_uri = "sip:#{addr}:#{port}"
        wanted = [
          %(modparam("siptrace", "duplicate_uri", "#{duplicate_uri}")),
          %(modparam("siptrace", "hep_mode_on", 1)),
          %(modparam("siptrace", "hep_version", 3)),
          %(modparam("siptrace", "hep_capture_id", #{capture_id})),
          # trace_on=1 statically: this kamailio build has no cfg.set_now_int RPC,
          # so the live toggle can't enable tracing — it must be on at boot.
          %(modparam("siptrace", "trace_on", 1)),
        ]

        # Already configured for exactly this collector → no change.
        return false if wanted.all? { |line| content.includes?(line) }

        # Strip any prior auto-managed block so we can rewrite cleanly.
        marker_begin = "# >>> voipappz hep (managed) >>>"
        marker_end   = "# <<< voipappz hep (managed) <<<"
        if content.includes?(marker_begin) && content.includes?(marker_end)
          before = content[0, content.index(marker_begin).not_nil!]
          after  = content[(content.index(marker_end).not_nil! + marker_end.size)..]
          # Drop the trailing newline left behind by the block.
          after = after.lstrip('\n')
          content = before + after
        end

        # Remove any standalone trace_on modparam so the flag lives only in the
        # managed block (avoids a later trace_on=0 overriding our trace_on=1).
        content = content.gsub(/modparam\("siptrace",\s*"trace_on",\s*\d+\)\s*\n?/, "")

        block = String.build do |io|
          io << marker_begin << "\n"
          io << "# HEP mirror to local collector — managed by `voipappz trace hep`.\n"
          wanted.each { |line| io << line << "\n" }
          io << marker_end << "\n"
        end

        # Anchor right after `loadmodule "siptrace.so"` (stable, always present;
        # we no longer set a siptrace db_url — capture is HEP→InfluxDB only).
        # Fall back to appending if the anchor isn't found.
        if (m = content.match(/loadmodule\s+"siptrace\.so"\s*\n/))
          content = content.sub(m[0], "#{m[0]}#{block}")
        else
          content = content.rstrip + "\n\n" + block
        end

        File.write(path, content)
        puts VoIPAppz::Colors.dim("  patched #{path} (capture_id #{capture_id})")
        true
      end

      # Resolve the collector address. kamailio has no loopback SIP socket, so it
      # cannot source the HEP duplicate to 127.0.0.1 — default to the kamailio
      # LAN listen IP (ip_address_internal from va.yaml) instead.
      def self.resolve_collector_addr(addr : String) : String
        return addr unless addr.empty? || addr == DEFAULT_HEP_ADDR
        config = begin
          DBHelper.load_config
        rescue
          return addr
        end
        si_ip = config.sip_interfaces.first?.try(&.profile["ip_address_internal"]?)
        node = config.nodes.find { |n| n.roles.includes?("switch") } || config.nodes.first?
        node_ip = node.try(&.profile["ip_address_internal"]?)
        ip = [si_ip, node_ip].find { |v| v && !v.empty? }
        ip || addr
      end

      # Returns the duplicate_uri currently declared in the ingress cfg, or ""
      # if none.
      def self.cfg_duplicate_uri : String
        return "" unless File.exists?(INGRESS_CFG)
        File.each_line(INGRESS_CFG) do |line|
          if (m = line.match(/modparam\("siptrace",\s*"duplicate_uri",\s*"([^"]+)"\)/))
            return m[1]
          end
        end
        ""
      end

      def self.cfg_hep_mode_on? : Bool
        return false unless File.exists?(INGRESS_CFG)
        File.read(INGRESS_CFG).includes?(%(modparam("siptrace", "hep_mode_on", 1)))
      end

      def self.kamcmd(*args : String) : Tuple(Int32, String)
        VoIPAppz::Docker.exec(DBHelper.container, ["kamcmd"] + args.to_a)
      end

      def self.restart_kamailio : Nil
        puts VoIPAppz::Colors.info("Restarting kamailio so the new HEP modparams take effect...")
        exit_code, stdout = VoIPAppz::Docker.compose(["restart", "kamailio-ingress"], capture: true)
        if exit_code == 0
          puts VoIPAppz::Colors.success("kamailio restarted")
        else
          STDERR.puts VoIPAppz::Colors.red("docker compose restart kamailio failed: #{stdout}")
          exit exit_code
        end
      end

      class Enable < Admiral::Command
        define_help description: "Enable HEP mirroring (patches kamailio.cfg, trace_on=1 live)"
        define_flag addr : String, description: "Collector address", default: "127.0.0.1"
        define_flag port : Int32, description: "Collector port", default: 9060
        define_flag no_restart : Bool, description: "Skip the kamailio restart", default: false

        def run
          addr = HepGroup.resolve_collector_addr(flags.addr)
          if addr != flags.addr
            puts VoIPAppz::Colors.dim("collector addr → #{addr} (kamailio LAN IP; it can't source HEP to 127.0.0.1)")
          end
          changed = HepGroup.ensure_cfg_patched(addr, flags.port)
          if changed
            puts VoIPAppz::Colors.success("HEP capture configured → sip:#{addr}:#{flags.port} (hep_mode_on=1, hep_version=3, trace_on=1)")
            HepGroup.restart_kamailio unless flags.no_restart
          else
            puts VoIPAppz::Colors.info("kamailio.cfg already mirrors to sip:#{addr}:#{flags.port} — no patch needed")
          end

          # On builds that support it, flip trace_on live too (no restart). When
          # it's absent the static trace_on=1 (applied on restart) already covers it.
          exit_code, _ = HepGroup.kamcmd("cfg.set_now_int", "siptrace", "trace_on", "1")
          if exit_code == 0
            puts VoIPAppz::Colors.success("siptrace trace_on=1 (live)")
          else
            puts VoIPAppz::Colors.dim("siptrace trace_on=1 set statically (live kamcmd toggle not available in this build)")
          end

          puts ""
          puts VoIPAppz::Colors.dim("Tip: stream the captured SIP with `voipappz trace hep listen --trace`")
        end
      end

      class Disable < Admiral::Command
        define_help description: "Pause HEP mirroring (trace_on=0 live; cfg untouched)"
        def run
          exit_code, stdout = HepGroup.kamcmd("cfg.set_now_int", "siptrace", "trace_on", "0")
          if exit_code == 0
            puts VoIPAppz::Colors.success("siptrace trace_on=0 (live, no restart)")
            puts VoIPAppz::Colors.dim("HEP modparams remain in kamailio.cfg — re-enable with `voipappz trace hep enable`")
          else
            STDERR.puts VoIPAppz::Colors.red("kamcmd cfg.set_now_int failed: #{stdout}")
            exit exit_code
          end
        end
      end

      class Status < Admiral::Command
        define_help description: "Show whether HEP mirroring is configured and currently on"
        def run
          dup_uri  = HepGroup.cfg_duplicate_uri
          hep_mode = HepGroup.cfg_hep_mode_on?

          puts VoIPAppz::Colors.bold("kamailio.cfg")
          if dup_uri.empty?
            puts "  duplicate_uri:  #{VoIPAppz::Colors.yellow("(not set)")}"
          else
            puts "  duplicate_uri:  #{VoIPAppz::Colors.green(dup_uri)}"
          end
          puts "  hep_mode_on:    #{hep_mode ? VoIPAppz::Colors.green("yes") : VoIPAppz::Colors.yellow("no")}"

          # Runtime trace_on flag
          exit_code, stdout = HepGroup.kamcmd("cfg.get", "siptrace", "trace_on")
          puts ""
          puts VoIPAppz::Colors.bold("runtime (kamcmd)")
          if exit_code == 0
            flag = stdout.strip
            label = flag == "1" ? VoIPAppz::Colors.green("ON") : VoIPAppz::Colors.yellow("OFF")
            puts "  trace_on:       #{label} (raw=#{flag})"
          else
            puts "  trace_on:       #{VoIPAppz::Colors.red("kamcmd unreachable")} (#{stdout.strip})"
          end
        end
      end

      class Listen < Admiral::Command
        define_help description: "Collect HEP traffic → InfluxDB. Add --trace to also print to stdout."
        define_flag addr : String, description: "Bind address (host:port)", default: "0.0.0.0:9060"
        define_flag method : String, description: "Method filter, e.g. INVITE,REGISTER", default: ""
        define_flag callid : String, description: "Show only this Call-ID", default: ""
        define_flag trace : Bool, description: "Print decoded SIP to stdout", default: false
        define_flag raw : Bool, description: "Also dump raw SIP payload (requires --trace)", default: false
        define_flag brief : Bool, description: "One compact line per packet (requires --trace)", default: false

        def run
          host, port = parse_bind(flags.addr)
          methods = parse_methods(flags.method)

          socket = UDPSocket.new
          begin
            socket.bind(host, port)
          rescue ex
            STDERR.puts VoIPAppz::Colors.red("Failed to bind #{flags.addr}: #{ex.message}")
            exit 1
          end
          socket.read_timeout = 1.seconds

          puts VoIPAppz::Colors.header("HEP listener — #{host}:#{port}")
          puts VoIPAppz::Colors.dim("→ InfluxDB #{VoIPAppz::InfluxDB::HOST}:#{VoIPAppz::InfluxDB::PORT} | trace=#{flags.trace} | Ctrl-C to stop")
          puts ""

          stop = Channel(Nil).new

          Signal::INT.trap { stop.send(nil) rescue nil; socket.close rescue nil }
          Signal::TERM.trap { stop.send(nil) rescue nil; socket.close rescue nil }

          buffer = Bytes.new(VoIPAppz::Hep::MAX_PACKET_LEN)
          count = 0_u64

          loop do
            begin
              bytes_read, _client = socket.receive(buffer)
              next if bytes_read == 0
              packet = buffer[0, bytes_read].dup
              msg = VoIPAppz::Hep::Decoder.decode(packet)
              next unless msg.proto_type == 1 # only SIP
              sip = msg.sip
              next unless sip

              if !methods.empty?
                tag = sip.cseq_method.upcase
                next unless methods.includes?(tag)
              end

              unless flags.callid.empty?
                next unless sip.call_id == flags.callid
              end

              count += 1
              render(msg, sip, flags.brief, flags.raw) if flags.trace
              VoIPAppz::InfluxDB.write(influx_line(msg, sip))
            rescue IO::TimeoutError
              next
            rescue VoIPAppz::Hep::ParseError
              next
            rescue IO::Error
              break
            end

            break if stop.closed?
          end

          puts ""
          puts VoIPAppz::Colors.dim("Stopped. #{count} SIP packets captured.")
        ensure
          socket.try &.close
        end

        private def parse_bind(addr : String) : {String, Int32}
          host, _, port = addr.rpartition(':')
          host = "0.0.0.0" if host.empty?
          {host, port.to_i? || DEFAULT_HEP_PORT}
        end

        private def parse_methods(s : String) : Array(String)
          return [] of String if s.strip.empty?
          s.split(',').map(&.strip.upcase).reject(&.empty?)
        end

        private def influx_line(msg : VoIPAppz::Hep::Message, sip : VoIPAppz::Hep::Sip::Message) : String
          method = sip.first_method.empty? ? sip.cseq_method : sip.first_method
          response = sip.first_resp.empty? ? "" : sip.first_resp
          ts_ns = msg.timestamp.to_unix_ns
          call_id = sip.call_id.gsub('"', "").gsub('\\', "")
          # Homer-compatible schema: measurement=hep, same tags/fields as homer lineproto.go
          tags = "proto_type=1,node_id=#{msg.node_id},node_name=#{msg.node_name},method=#{method}"
          tags += ",response=#{response}" unless response.empty?
          fields = "src_ip=\"#{msg.src_ip}\",src_port=#{msg.src_port}i," \
                   "dst_ip=\"#{msg.dst_ip}\",dst_port=#{msg.dst_port}i," \
                   "payload_len=#{msg.payload.bytesize}i," \
                   "call_id=\"#{call_id}\",from_user=\"#{sip.from_user}\",to_user=\"#{sip.to_user}\""
          fields += ",cid=\"#{msg.cid}\"" unless msg.cid.empty?
          "hep,#{tags} #{fields} #{ts_ns}"
        end

        private def render(msg : VoIPAppz::Hep::Message, sip : VoIPAppz::Hep::Sip::Message, brief : Bool, raw : Bool)
          ts = msg.timestamp.to_local.to_s("%H:%M:%S.%3N")
          flow = "#{msg.src_ip}:#{msg.src_port} → #{msg.dst_ip}:#{msg.dst_port}"

          # Direction / kind: request vs response
          if !sip.first_resp.empty?
            kind = "#{sip.first_resp} #{sip.first_resp_text}".strip
            method_lbl = VoIPAppz::Colors.cyan(sip.cseq_method.ljust(8))
            status_lbl = colorize_status(sip.first_resp, kind)
          else
            kind = ""
            method_lbl = VoIPAppz::Colors.bold(VoIPAppz::Colors.cyan(sip.first_method.ljust(8)))
            status_lbl = ""
          end

          if brief
            line = "#{VoIPAppz::Colors.dim(ts)}  #{method_lbl} #{status_lbl.ljust(14)} #{flow.ljust(46)}  #{VoIPAppz::Colors.dim(sip.call_id)}"
            puts line
            return
          end

          puts VoIPAppz::Colors.divider
          puts "#{VoIPAppz::Colors.dim(ts)}  #{method_lbl} #{status_lbl}  #{VoIPAppz::Colors.bold(flow)}"
          puts "  from:     #{sip.from_user}@#{sip.from_host}  #{VoIPAppz::Colors.dim("tag=" + sip.from_tag)}" unless sip.from_user.empty? && sip.from_host.empty?
          puts "  to:       #{sip.to_user}@#{sip.to_host}#{sip.to_tag.empty? ? "" : "  " + VoIPAppz::Colors.dim("tag=" + sip.to_tag)}" unless sip.to_user.empty? && sip.to_host.empty?
          puts "  call-id:  #{VoIPAppz::Colors.dim(sip.call_id)}"
          puts "  cseq:     #{sip.cseq_val}" unless sip.cseq_val.empty?
          puts "  ua:       #{sip.user_agent}" unless sip.user_agent.empty?
          puts "  server:   #{sip.server}" unless sip.server.empty?
          puts "  contact:  #{sip.contact_user}@#{sip.contact_host}#{sip.contact_port > 0 ? ":#{sip.contact_port}" : ""}" unless sip.contact_user.empty? && sip.contact_host.empty?
          puts "  reason:   #{sip.reason_val}" unless sip.reason_val.empty?
          puts "  profile:  #{msg.profile}  node=#{msg.node_name}"

          if raw
            puts VoIPAppz::Colors.dim("  --- raw payload ---")
            msg.payload.lines.first(60).each { |l| puts "    #{l.rstrip}" }
          end
        end

        private def colorize_status(code : String, text : String) : String
          c = code.to_i? || 0
          painted = case c
                    when 100..199 then VoIPAppz::Colors.dim(text)
                    when 200..299 then VoIPAppz::Colors.green(text)
                    when 300..399 then VoIPAppz::Colors.blue(text)
                    when 400..499 then VoIPAppz::Colors.yellow(text)
                    when 500..599 then VoIPAppz::Colors.red(text)
                    else               text
                    end
          painted
        end
      end

      # Build a synthetic HEP3 packet wrapping a SIP payload — shared by
      # `send` (manual probe) and `selftest` (self-contained e2e).
      def self.build_hep3(sip : String,
                         src_ip : String = "10.0.0.42", src_port : UInt16 = 5060_u16,
                         dst_ip : String = "10.0.0.99", dst_port : UInt16 = 5060_u16,
                         node_id : UInt32 = 2001_u32, node_name : String = "voipappz-hep-send") : Bytes
        chunks = IO::Memory.new

        write_chunk(chunks, VoIPAppz::Hep::VERSION_CHUNK, Bytes[2_u8])
        write_chunk(chunks, VoIPAppz::Hep::PROTOCOL_CHUNK, Bytes[17_u8])

        src_bytes = ipv4_bytes(src_ip)
        dst_bytes = ipv4_bytes(dst_ip)
        write_chunk(chunks, VoIPAppz::Hep::IP4_SRC_IP_CHUNK, src_bytes)
        write_chunk(chunks, VoIPAppz::Hep::IP4_DST_IP_CHUNK, dst_bytes)

        port = Bytes.new(2)
        IO::ByteFormat::BigEndian.encode(src_port, port)
        write_chunk(chunks, VoIPAppz::Hep::SRC_PORT_CHUNK, port)
        port2 = Bytes.new(2)
        IO::ByteFormat::BigEndian.encode(dst_port, port2)
        write_chunk(chunks, VoIPAppz::Hep::DST_PORT_CHUNK, port2)

        tsec = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(Time.utc.to_unix.to_u32, tsec)
        write_chunk(chunks, VoIPAppz::Hep::TSEC_CHUNK, tsec)
        tmsec = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(0_u32, tmsec)
        write_chunk(chunks, VoIPAppz::Hep::TMSEC_CHUNK, tmsec)

        write_chunk(chunks, VoIPAppz::Hep::PROTO_TYPE_CHUNK, Bytes[1_u8])

        nid = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(node_id, nid)
        write_chunk(chunks, VoIPAppz::Hep::NODE_ID_CHUNK, nid)
        write_chunk(chunks, VoIPAppz::Hep::NODE_NAME_CHUNK, node_name.to_slice)

        write_chunk(chunks, VoIPAppz::Hep::PAYLOAD_CHUNK, sip.to_slice)

        body = chunks.to_slice
        total = 6_u16 + body.size.to_u16
        out = IO::Memory.new
        out.write("HEP3".to_slice)
        len = Bytes.new(2)
        IO::ByteFormat::BigEndian.encode(total, len)
        out.write(len)
        out.write(body)
        out.to_slice
      end

      private def self.write_chunk(io : IO::Memory, ctype : UInt16, body : Bytes) : Nil
        head = Bytes.new(6)
        IO::ByteFormat::BigEndian.encode(0_u16, head[0, 2])             # vendor_id
        IO::ByteFormat::BigEndian.encode(ctype, head[2, 2])             # type
        IO::ByteFormat::BigEndian.encode(6_u16 + body.size.to_u16, head[4, 2])  # length
        io.write(head)
        io.write(body)
      end

      private def self.ipv4_bytes(ip : String) : Bytes
        parts = ip.split('.').map(&.to_u8)
        raise "bad IPv4 #{ip}" unless parts.size == 4
        Bytes[parts[0], parts[1], parts[2], parts[3]]
      end

      def self.sample_invite(callid : String = "voipappz-hep-probe-#{Time.utc.to_unix}") : String
        <<-SIP
        INVITE sip:1001@apoint.voipappz.io SIP/2.0\r
        Via: SIP/2.0/UDP 10.0.0.42:5060;branch=z9hG4bK-probe\r
        Max-Forwards: 70\r
        From: "Probe" <sip:probe@apoint.voipappz.io>;tag=probe-ft\r
        To: <sip:1001@apoint.voipappz.io>\r
        Call-ID: #{callid}\r
        CSeq: 1 INVITE\r
        User-Agent: voipappz-hep-probe/0.1\r
        Contact: <sip:probe@10.0.0.42:5060>\r
        Content-Length: 0\r
        \r

        SIP
      end

      class Send < Admiral::Command
        define_help description: "Emit a synthetic HEP3 INVITE to a collector"
        define_flag addr : String, description: "Collector host", default: "127.0.0.1"
        define_flag port : Int32, description: "Collector port", default: 9060
        define_flag count : Int32, description: "How many packets to send", default: 1
        define_flag callid : String, description: "Override the Call-ID", default: ""

        def run
          socket = UDPSocket.new
          base_callid = flags.callid.empty? ? "voipappz-hep-probe-#{Time.utc.to_unix}" : flags.callid

          flags.count.times do |i|
            cid = flags.count == 1 ? base_callid : "#{base_callid}-#{i + 1}"
            sip = HepGroup.sample_invite(cid)
            packet = HepGroup.build_hep3(sip)
            socket.send(packet, to: Socket::IPAddress.new(flags.addr, flags.port))
            puts VoIPAppz::Colors.success("sent HEP3 INVITE call-id=#{cid} (#{packet.size}B) → #{flags.addr}:#{flags.port}")
          end
        ensure
          socket.try &.close
        end
      end

      # End-to-end self test: spin up a listener fiber on a free port,
      # send a synthetic HEP3 INVITE to it, assert the decoded SIP matches.
      # No external dependencies — runs anywhere the CLI runs, including CI.
      class Selftest < Admiral::Command
        define_help description: "Round-trip HEP self-test (no kamailio required)"
        define_flag port : Int32, description: "Bind port (0 = pick free)", default: 0

        def run
          socket = UDPSocket.new
          socket.bind("127.0.0.1", flags.port)
          bound_port = socket.local_address.port
          socket.read_timeout = 3.seconds

          callid = "voipappz-hep-selftest-#{Time.utc.to_unix}-#{Random.rand(10000)}"
          sip = HepGroup.sample_invite(callid)
          packet = HepGroup.build_hep3(sip)

          puts VoIPAppz::Colors.bold("HEP self-test")
          puts "  listener:  127.0.0.1:#{bound_port}"
          puts "  call-id:   #{callid}"
          puts "  payload:   #{packet.size}B HEP3 INVITE"
          puts ""

          # Send to ourselves; receive synchronously.
          sender = UDPSocket.new
          sender.send(packet, to: Socket::IPAddress.new("127.0.0.1", bound_port))
          sender.close

          buffer = Bytes.new(VoIPAppz::Hep::MAX_PACKET_LEN)
          begin
            bytes_read, _ = socket.receive(buffer)
          rescue IO::TimeoutError
            STDERR.puts VoIPAppz::Colors.red("FAIL: listener did not receive the packet within 3s")
            exit 1
          end

          msg = VoIPAppz::Hep::Decoder.decode(buffer[0, bytes_read].dup)
          parsed = msg.sip

          if parsed.nil?
            STDERR.puts VoIPAppz::Colors.red("FAIL: HEP decoded but no SIP message parsed")
            exit 1
          end

          ok = true
          # HEP3 chunk type 1 is the IP address family, not the envelope
          # version. The "HEP3" magic above already proves the envelope.
          ok &&= check("IPv4 address family", msg.version == 2)
          ok &&= check("proto_type == SIP (1)", msg.proto_type == 1)
          ok &&= check("call-id matches", parsed.call_id == callid)
          ok &&= check("method INVITE", parsed.first_method == "INVITE")
          ok &&= check("profile call", msg.profile == "call")
          ok &&= check("src 10.0.0.42:5060", msg.src_ip == "10.0.0.42" && msg.src_port == 5060)
          ok &&= check("dst 10.0.0.99:5060", msg.dst_ip == "10.0.0.99" && msg.dst_port == 5060)
          ok &&= check("node_name", msg.node_name == "voipappz-hep-send")

          puts ""
          if ok
            puts VoIPAppz::Colors.green("PASS — HEP encode/decode round-trip OK")
          else
            STDERR.puts VoIPAppz::Colors.red("FAIL — see above")
            exit 1
          end
        ensure
          socket.try &.close
        end

        private def check(label : String, condition : Bool) : Bool
          if condition
            puts "  #{VoIPAppz::Colors.green(VoIPAppz::Colors::CHECK)} #{label}"
          else
            puts "  #{VoIPAppz::Colors.red(VoIPAppz::Colors::CROSS)} #{label}"
          end
          condition
        end
      end

      class Query < Admiral::Command
        define_help description: "Query SIP history from InfluxDB (requires --store captures)"
        define_flag from : String, description: "Time window, e.g. 1h, 30m, 24h", default: "1h"
        define_flag method : String, description: "Filter by SIP method, e.g. INVITE", default: ""
        define_flag ip : String, description: "Filter by source IP", default: ""
        define_flag callid : String, description: "Filter by Call-ID", default: ""
        define_flag lines : Int32, description: "Max rows to return", default: 50

        def run
          unless VoIPAppz::InfluxDB.ping
            STDERR.puts VoIPAppz::Colors.error("InfluxDB not reachable (#{VoIPAppz::InfluxDB::HOST}:#{VoIPAppz::InfluxDB::PORT})")
            exit 1
          end

          where = ["time > now() - #{flags.from}"]
          where << "method = '#{flags.method.upcase}'" unless flags.method.empty?
          where << "src_ip = '#{flags.ip}'" unless flags.ip.empty?
          where << "call_id =~ /#{flags.callid}/" unless flags.callid.empty?

          q = "SELECT time, method, response, src_ip, src_port, call_id, from_user, to_user " \
              "FROM hep WHERE #{where.join(" AND ")} " \
              "ORDER BY time DESC LIMIT #{flags.lines}"

          result = VoIPAppz::InfluxDB.raw_query(q)
          series = result.dig?("results", 0, "series", 0)
          unless series
            puts VoIPAppz::Colors.dim("No SIP records found in the last #{flags.from}.")
            return
          end

          columns = series["columns"].as_a.map(&.as_s)
          values = series["values"].as_a.map(&.as_a)

          time_i   = columns.index("time") || 0
          method_i = columns.index("method") || 1
          resp_i   = columns.index("response") || 2
          src_i    = columns.index("src_ip") || 3
          cid_i    = columns.index("call_id") || 5
          from_i   = columns.index("from_user") || 6
          to_i     = columns.index("to_user") || 7

          rows = values.reverse.map do |row|
            ts     = format_ts(row[time_i]?.try(&.as_s?) || "")
            meth   = row[method_i]?.try(&.as_s?) || "-"
            resp   = row[resp_i]?.try(&.as_s?) || ""
            src    = row[src_i]?.try(&.as_s?) || "-"
            cid    = (row[cid_i]?.try(&.as_s?) || "-")[0, 32]
            from_v = row[from_i]?.try(&.as_s?) || "-"
            to_v   = row[to_i]?.try(&.as_s?) || "-"

            meth_c = VoIPAppz::Colors.cyan(meth.ljust(8))
            resp_c = resp.empty? ? VoIPAppz::Colors.dim("-    ") : colorize_status(resp).ljust(5)

            "#{VoIPAppz::Colors.dim(ts)}  #{meth_c}  #{src.ljust(15)}  #{resp_c}  #{VoIPAppz::Colors.dim(from_v)} → #{VoIPAppz::Colors.dim(to_v)}  #{VoIPAppz::Colors.dim(cid)}"
          end

          puts VoIPAppz::Colors.header("SIP history — last #{flags.from} (#{rows.size} records)")
          puts VoIPAppz::Colors.dim("%-19s  %-8s  %-15s  %-5s  %s" % ["time", "method", "src_ip", "resp", "from → to  call_id"])
          puts VoIPAppz::Colors.dim("-" * 80)
          rows.each { |r| puts r }
        end

        private def format_ts(raw : String) : String
          raw.sub("T", " ").sub(/\.\d+Z$/, "").sub("Z", "")
        end

        private def colorize_status(code : String) : String
          n = code.to_i? || 0
          case n
          when 100..199 then VoIPAppz::Colors.dim(code)
          when 200..299 then VoIPAppz::Colors.green(code)
          when 300..399 then VoIPAppz::Colors.yellow(code)
          when 400..499 then VoIPAppz::Colors.red(code)
          when 500..599 then VoIPAppz::Colors.red(VoIPAppz::Colors.bold(code))
          else               code
          end
        end
      end
    end
  end
end
