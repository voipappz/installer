require "admiral"
require "../helpers/colors"
require "../helpers/freeswitch"
require "../helpers/table"
require "../helpers/docker"
require "../helpers/services"
require "../helpers/dispatcher_list"
require "./sbc"

module VoIPAppz::Commands
  # The SIP plane, grouped under one SBC namespace and addressed by the box you
  # actually mean.
  #
  #   voipappz sbc ingress ...   the app-plane forwarder   (va-ingress)
  #   voipappz sbc egress  ...   the voip-plane SBC        (va-egress)
  #   voipappz trace hep     ... plane-wide HEP capture
  #   voipappz pbx         ...   FreeSWITCH                (va-voip)
  #
  # The two boxes do not store the same way: the ingress is file-backed
  # (config/kamailio/ingress/dispatcher.list, no database at all) and the egress is
  # SQLite-backed. Explicit `sbc ingress` and `sbc egress` branches retain that
  # safety: no shared command ever guesses which running Kamailio to use.
  #
  # These are thin: they pin the scope and delegate to the implementations in
  # sbc.cr, so each operation still has exactly one copy.
  private module Delegate
    # Run a shared sub-command with the kamailio scope pinned.
    def self.scoped(scope : Symbol, cmd : Admiral::Command.class, args : Array(String) = [] of String)
      VoIPAppz::Commands::Kamailio::DBHelper.with_scope(scope) do
        cmd.new(args).run
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ingress — the app-plane forwarder (va-ingress)
  # ---------------------------------------------------------------------------
  class Ingress < Admiral::Command
    define_help description: "INGRESS kamailio (va-ingress) — the app-plane forwarder"

    register_sub_command sync, type: Sync
    register_sub_command list, type: List
    register_sub_command reload, type: Reload
    register_sub_command status, type: Status
    register_sub_command shell, type: Shell

    def run
      puts help
      puts VoIPAppz::Colors.dim("The ingress has NO DATABASE: its destinations are #{VoIPAppz::DispatcherList::HOST_PATH},")
      puts VoIPAppz::Colors.dim("generated from config/va.yaml. Registration, presence, media and carrier")
      puts VoIPAppz::Colors.dim("egress all belong to `voipappz sbc egress`.")
    end

    class Sync < Admiral::Command
      define_help description: "Regenerate dispatcher.list from config/va.yaml; reload the ingress"

      def run
        Delegate.scoped(:ingress, VoIPAppz::Commands::Kamailio::Sync)
      end
    end

    class List < Admiral::Command
      define_help description: "Show the ingress's destinations (file + what kamailio loaded)"

      def run
        path = VoIPAppz::DispatcherList.host_path
        puts VoIPAppz::Colors.bold("#{path}")
        if File.exists?(path)
          rows = File.read_lines(path).reject { |l| l.strip.empty? || l.starts_with?("#") }
          if rows.empty?
            puts VoIPAppz::Colors.yellow("  empty — the ingress fails closed (404s every call) until `voipappz sbc ingress sync`")
          else
            rows.each { |l| puts "  #{l}" }
          end
        else
          puts VoIPAppz::Colors.red("  missing — run `voipappz setup` or `voipappz sbc ingress sync`")
          puts VoIPAppz::Colors.dim("  compose bind-mounts this path; while it is absent docker mounts an empty DIRECTORY over it")
        end

        # What the running box actually has loaded, which is the thing that
        # routes calls — the file on disk is only what it will load next reload.
        return unless c = VoIPAppz::Docker.ingress_container
        return unless VoIPAppz::Docker.running_kamailios.includes?(c)
        puts ""
        puts VoIPAppz::Colors.bold("loaded in #{c}:")
        _, loaded = VoIPAppz::Docker.exec(c, ["kamcmd", "dispatcher.list"])
        targets = VoIPAppz::DispatcherList.parse_kamcmd(loaded)

        if targets.empty?
          puts VoIPAppz::Colors.yellow("  nothing loaded — run `voipappz sbc ingress sync`")
          return
        end

        # DECODED, not the raw two-letter flags. kamcmd prints "DX"/"IP" and
        # says nothing about what they mean, so an operator reads every D as a
        # fault — and for set 100 that is backwards, because a carrier SOURCE
        # is identified rather than dialled and disabled is the correct state.
        # Meanwhile a routing target going Inactive because FreeSWITCH stopped
        # answering keepalives is a genuine outage that looked identical.
        rows = targets.map do |t|
          state = case
                  when t.source_only? then VoIPAppz::Colors.dim(t.state)
                  when t.usable?      then VoIPAppz::Colors.green(t.state)
                  else                     VoIPAppz::Colors.red(t.state)
                  end
          [t.setid.to_s, t.uri, state, t.note]
        end
        puts VoIPAppz::Table.render([
          VoIPAppz::Table::Column.new("set", 5),
          VoIPAppz::Table::Column.new("destination", 30),
          VoIPAppz::Table::Column.new("state", 10),
          VoIPAppz::Table::Column.new("", 42),
        ], rows)

        routable = targets.reject(&.source_only?)
        down = routable.reject(&.usable?)
        if routable.empty?
          puts VoIPAppz::Colors.red("  No routing targets at all — every call will 404.")
        elsif down.size == routable.size
          puts VoIPAppz::Colors.red("  Every routing target is down — calls will 404.")
          puts VoIPAppz::Colors.dim("  The dispatcher pings each destination with OPTIONS and drops it after 3 misses,")
          puts VoIPAppz::Colors.dim("  so this usually means FreeSWITCH is not running or not reachable at that address.")
        elsif !down.empty?
          puts VoIPAppz::Colors.yellow("  #{down.size} of #{routable.size} routing targets are down.")
        end

        # AND SAY IT IN THE EXIT CODE. This printed "every call will 404" and
        # exited 0 — a command reporting total routing failure while reporting
        # success to anything that reads status rather than stdout. Partial
        # loss stays 0: the set still routes, and the yellow line is the report.
        exit VoIPAppz::DispatcherList::EXIT_DOWN if VoIPAppz::DispatcherList.routing(targets).down?
      end
    end

    class Reload < Admiral::Command
      define_help description: "Re-read dispatcher.list in the running ingress (no restart)"

      def run
        Delegate.scoped(:ingress, VoIPAppz::Commands::Kamailio::Reload)
      end
    end

    class Status < Admiral::Command
      define_help description: "Ingress health and loaded destinations"

      # Deliberately NOT delegating to the shared Status: that one reads the
      # kamailio SQLite database, which the ingress does not have. Pointing it
      # here is exactly the bug that made `sbc status` fail with a bare
      # "sqlite3 (in va-ingress) failed".
      def run
        c = VoIPAppz::Docker.ingress_container
        unless c && VoIPAppz::Docker.running_kamailios.includes?(c)
          STDERR.puts VoIPAppz::Colors.red("va-ingress is not running.")
          STDERR.puts VoIPAppz::Colors.dim("  Start it: voipappz up -p app")
          exit 1
        end

        puts VoIPAppz::Colors.bold("kamailio-ingress (#{c})")
        _, uptime = VoIPAppz::Docker.exec(c, ["kamcmd", "core.uptime"])
        uptime.lines.each { |l| puts "  #{l}" unless l.strip.empty? }
        puts ""
        Ingress::List.new([] of String).run
      end
    end

    class Shell < Admiral::Command
      define_help description: "Open a shell in the ingress container"

      def run
        SipShell.open("kamailio-ingress")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # egress — the voip-plane SBC (va-egress)
  # ---------------------------------------------------------------------------
  class Egress < Admiral::Command
    define_help description: "EGRESS kamailio (va-egress) — the voip-plane SBC / registrar"

    register_sub_command sync, type: Sync
    register_sub_command status, type: Status
    register_sub_command list, type: List
    register_sub_command reload, type: Reload
    register_sub_command shell, type: Shell
    # The egress owns all the real state, so these groups only ever made sense
    # here. Delegated to the existing implementations rather than copied.
    register_sub_command dispatcher, type: VoIPAppz::Commands::Kamailio::DispatcherGroup
    register_sub_command address, type: VoIPAppz::Commands::Kamailio::AddressGroup
    register_sub_command domain, type: VoIPAppz::Commands::Kamailio::DomainGroup
    register_sub_command subscriber, type: VoIPAppz::Commands::Kamailio::SubscriberGroup
    register_sub_command db, type: VoIPAppz::Commands::Kamailio::DbGroup
    register_sub_command trace, type: VoIPAppz::Commands::Kamailio::TraceGroup

    def run
      puts help
      puts VoIPAppz::Colors.dim("The egress is the SBC: registration, presence, NAT/SDP, carrier egress and")
      puts VoIPAppz::Colors.dim("wss all live here, and it takes calls DIRECTLY from providers as well as")
      puts VoIPAppz::Colors.dim("through the ingress. It is SQLite-backed — see `voipappz sbc egress db`.")
    end

    class Sync < Admiral::Command
      define_help description: "Seed kamailio's SQLite from config/va.yaml and reload"

      def run
        Delegate.scoped(:egress, VoIPAppz::Commands::Kamailio::Sync)
      end
    end

    class Status < Admiral::Command
      define_help description: "Kamailio health, registrations and loaded data"

      def run
        Delegate.scoped(:egress, VoIPAppz::Commands::Kamailio::Status)
      end
    end

    class List < Admiral::Command
      define_help description: "Show the dispatcher/address/domain rows"

      def run
        Delegate.scoped(:egress, VoIPAppz::Commands::Kamailio::List)
      end
    end

    class Reload < Admiral::Command
      define_help description: "Reload kamailio modules (dispatcher, permissions, domain)"

      def run
        Delegate.scoped(:egress, VoIPAppz::Commands::Kamailio::Reload)
      end
    end

    class Shell < Admiral::Command
      define_help description: "Open a shell where kamailio runs"

      def run
        SipShell.open("kamailio-egress")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # sbc — one namespace, with explicit ingress/egress targets
  # ---------------------------------------------------------------------------
  class Sbc < Admiral::Command
    {% if flag?(:node_runtime) %}
      # A NODE RUNS ONE KAMAILIO. Naming a direction there is a distinction
      # without a difference — there is no ingress box to tell it apart from —
      # so the level is dropped and it reads `sbc status`, `sbc subscriber add`.
      # The host build has both boxes and therefore keeps ingress/egress.
      define_help description: "Session border controller — this node's kamailio"

      register_sub_command sync, type: Egress::Sync
      register_sub_command status, type: Egress::Status
      register_sub_command list, type: Egress::List
      register_sub_command reload, type: Egress::Reload
      register_sub_command shell, type: Egress::Shell
      register_sub_command dispatcher, type: VoIPAppz::Commands::Kamailio::DispatcherGroup
      register_sub_command address, type: VoIPAppz::Commands::Kamailio::AddressGroup
      register_sub_command domain, type: VoIPAppz::Commands::Kamailio::DomainGroup
      register_sub_command subscriber, type: VoIPAppz::Commands::Kamailio::SubscriberGroup
      register_sub_command db, type: VoIPAppz::Commands::Kamailio::DbGroup
      register_sub_command trace, type: VoIPAppz::Commands::Kamailio::TraceGroup
      # BACK-COMPAT, not a second surface. `sbc egress ...` is what installed
      # nodes and the installer already run (installer/install.sh applies the
      # mounted YAML with `sbc egress sync` after start), and an upgrade must
      # not break a node that is already on disk. Undocumented in the help
      # above it: the flattened names are the ones to learn.
      register_sub_command egress, type: Egress
    {% else %}
      define_help description: "Session border controllers — ingress and egress"

      register_sub_command ingress, type: Ingress
      register_sub_command egress, type: Egress
    {% end %}
    # SIP capture lives on the node, not on either kamailio: status/switch on
    # loopback, live tail over the broker, history from InfluxDB.
    register_sub_command hep, type: VoIPAppz::Commands::SbcHep

    def run
      puts help
    end
  end

  # HEP patches both Kamailio configurations, so it belongs to the top-level
  # trace branch rather than to either directional box.
  class Trace < Admiral::Command
    define_help description: "SIP tracing and capture"

    register_sub_command hep, type: VoIPAppz::Commands::Kamailio::HepGroup

    def run
      puts help
    end
  end

  # ---------------------------------------------------------------------------
  # pbx — FreeSWITCH (va-voip)
  # ---------------------------------------------------------------------------
  class Pbx < Admiral::Command
    define_help description: "FreeSWITCH (va-voip) — the PBX itself"

    register_sub_command shell, type: Shell
    register_sub_command cli, type: Cli
    register_sub_command status, type: Status

    def run
      puts help
    end

    class Cli < Admiral::Command
      define_help description: "Open fs_cli in the FreeSWITCH container (-x runs one command)"

      define_flag execute : String,
        description: "Run one fs_cli command and exit instead of a console",
        short: x,
        default: ""

      def run
        args = ["fs_cli"]
        args += ["-x", flags.execute] unless flags.execute.empty?
        SipShell.exec("freeswitch", args, interactive: flags.execute.empty?)
      end
    end

    class Shell < Admiral::Command
      define_help description: "Open a shell in the FreeSWITCH container"

      def run
        SipShell.open("freeswitch")
      end
    end

    class Status < Admiral::Command
      define_help description: "FreeSWITCH status (fs_cli -x status)"

      def run
        SipShell.exec("freeswitch", ["fs_cli", "-x", "status"], interactive: false)
      end
    end
  end

  # Container entry for the SIP-plane groups. Resolves through the Services
  # catalog like everything else — container names are role-based (va-app,
  # va-voip, va-ingress, va-egress) and no longer derive from the service name,
  # so hardcoding one is how you get "No such container" on a renamed node.
  module SipShell
    extend self

    def open(service : String)
      # sh, not bash: the kamailio image is Debian-slim-ish and FreeSWITCH's is
      # not guaranteed to carry bash. sh is always there.
      exec(service, ["sh"], interactive: true)
    end

    def exec(service : String, cmd : Array(String), interactive : Bool)
      # One `docker ps`, not two: resolve_container already fetched and searched
      # this exact list, and every `sbc ingress shell` / `pbx cli` paid for both.
      running = VoIPAppz::Docker.running_containers
      container = if VoIPAppz::Docker.local_exec?
                    VoIPAppz::Docker::LOCAL
                  else
                    VoIPAppz::Docker.resolve_container(service)
                  end
      unless running.includes?(container)
        STDERR.puts VoIPAppz::Colors.red("#{container} is not running.")
        svc = VoIPAppz::Services.find?(service)
        if svc && (profile = svc.profiles.first?)
          STDERR.puts VoIPAppz::Colors.dim("  Start it: voipappz up -p #{profile}")
        end
        exit 1
      end

      # Every PBX entry point gets the same explicit ESL connection. Without
      # this, fs_cli silently tries its default password and reports the vague
      # "Error Connecting []" seen by operators.
      if service == "freeswitch" && cmd.first? == "fs_cli"
        password = VoIPAppz::FreeSwitch.esl_password(container)
        if password.empty?
          STDERR.puts VoIPAppz::Colors.red("Cannot connect to FreeSWITCH: ESL password is unavailable.")
          STDERR.puts VoIPAppz::Colors.dim("  Check #{VoIPAppz::FreeSwitch::CONFIG_PATH} in #{container} or VA_FREESWITCH_PASSWORD in .env.")
          exit 1
        end
        cmd = VoIPAppz::FreeSwitch.cli_args(password, cmd[1..])

        # Probe before attaching interactively so a PBX that has not started
        # produces one useful message instead of fs_cli's error plus its full
        # usage screen. Non-interactive commands are captured for the same
        # reason and printed only when successful.
        if interactive
          probe_output = IO::Memory.new
          probe_args = VoIPAppz::FreeSwitch.cli_args(password, ["-x", "status"])
          probe = if VoIPAppz::Docker.local_exec?
                    Process.run(probe_args[0], probe_args[1..],
                      output: probe_output, error: probe_output)
                  else
                    Process.run("docker", ["exec", container] + probe_args,
                      output: probe_output, error: probe_output)
                  end
          report_esl_unavailable(container) unless probe.success?
        else
          output = IO::Memory.new
          status = if VoIPAppz::Docker.local_exec?
                     Process.run(cmd[0], cmd[1..], output: output, error: output)
                   else
                     Process.run("docker", ["exec", "-i", container] + cmd,
                       output: output, error: output)
                   end
          if status.success?
            print output.to_s
            return
          end
          report_esl_unavailable(container)
        end
      end

      status = if VoIPAppz::Docker.local_exec?
                 Process.run(cmd[0], cmd[1..],
                   input: Process::Redirect::Inherit,
                   output: Process::Redirect::Inherit,
                   error: Process::Redirect::Inherit)
               else
                 args = ["exec", (interactive ? "-it" : "-i"), container] + cmd
                 Process.run("docker", args,
                   input: Process::Redirect::Inherit,
                   output: Process::Redirect::Inherit,
                   error: Process::Redirect::Inherit)
               end
      exit status.exit_code unless status.success?
    end

    private def report_esl_unavailable(container : String) : NoReturn
      STDERR.puts VoIPAppz::Colors.red("FreeSWITCH ESL is not ready in #{container}.")
      STDERR.puts VoIPAppz::Colors.dim("  va-node must be healthy before FreeSWITCH starts. Run: voipappz health")
      exit 1
    end
  end
end
