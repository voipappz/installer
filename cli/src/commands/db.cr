require "admiral"
require "../helpers/docker"
require "../helpers/colors"

module VoIPAppz::Commands
  # Database lifecycle for the app DB(s). Encapsulates the fresh-install /
  # reset dance that used to be a manual 10-step process (find the pgEdge
  # `voipappz.sql` stub, force-load db/schema.sql, apply migrations, dump…).
  #
  # Source of truth for the schema is the APP's own migrations — we run them
  # inside the `web` container (`db/schema.sql` + `db/migrate/*` via Sequel),
  # so `db init`/`migrate` always match the deployed API version rather than a
  # snapshot that can drift. Inspection goes straight to the postgres
  # container (reads its own POSTGRES_PASSWORD, so the CLI never needs the pw).
  #
  #   voipappz db status              # DBs, table counts, migration state (read-only)
  #   voipappz db init                # idempotent: load schema if the app DB is empty
  #   voipappz db migrate             # apply any pending migrations
  #   voipappz db reset [--yes]       # DESTRUCTIVE: drop+recreate the app DB, reload schema
  class Db < Admiral::Command
    define_help description: "Database lifecycle: status | init | migrate | reset"

    define_argument action : String, description: "status | init | migrate | reset"
    define_flag yes : Bool, description: "Skip the confirmation prompt (reset)", default: false
    define_flag database : String, description: "Target app database", default: "voipappz"

    # The table whose presence means "app schema is loaded" (created by the
    # 1018935454_create_event_store migration; the very thing whose absence
    # crash-loops the API at boot).
    SENTINEL_TABLE = "event_store_events"

    def run
      case arguments.action
      when "status"  then status
      when "init"    then init
      when "migrate" then migrate
      when "reset"   then reset
      else
        STDERR.puts VoIPAppz::Colors.red("Unknown action: #{arguments.action || "(none)"}")
        STDERR.puts "Usage: voipappz db status | init | migrate | reset [--yes]"
        exit 1
      end
    end

    # ---- inspection (straight to the postgres container) -------------------

    # Run a query in the postgres container, using its own POSTGRES_PASSWORD so
    # the CLI needs no credentials. `-tAc` → tuples-only, unaligned, one query.
    private def psql(db : String, sql : String) : {Int32, String}
      VoIPAppz::Docker.exec("postgres",
        ["sh", "-c", "PGPASSWORD=\"$POSTGRES_PASSWORD\" psql -U postgres -d #{db} -tAc #{sql.inspect}"])
    end

    private def schema_loaded?(db : String) : Bool
      _, out = psql(db, "SELECT to_regclass('public.#{SENTINEL_TABLE}') IS NOT NULL")
      out.strip == "t"
    end

    private def status
      code, dbs = psql("postgres",
        "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname<>'postgres' ORDER BY 1")
      if code != 0
        STDERR.puts VoIPAppz::Colors.red("Cannot reach postgres — is the app profile up? (`voipappz up -p app`)")
        exit 1
      end
      puts VoIPAppz::Colors.bold("Databases")
      dbs.each_line.map(&.strip).reject(&.empty?).each do |db|
        _, tables = psql(db, "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
        loaded = schema_loaded?(db)
        mig = "-"
        if loaded
          _, m = psql(db, "SELECT count(*) FROM schema_migrations")
          mig = m.strip
        end
        mark = db == flags.database ? (loaded ? VoIPAppz::Colors.green("✔ schema") : VoIPAppz::Colors.red("✘ no schema")) : ""
        puts "  #{db.ljust(12)} tables=#{tables.strip.ljust(4)} migrations=#{mig.ljust(4)} #{mark}"
      end
    end

    # ---- schema load / migrate (via the web container's own migrations) ----

    # Run a Ruby snippet inside a throwaway `web` container (no deps started).
    # The API image carries db/schema.sql + db/migrate + Sequel, and gets
    # DATABASE_URL from the compose env — so this is the app's real migrator.
    private def web_ruby(ruby : String) : Int32
      code, _ = VoIPAppz::Docker.compose(
        ["run", "--rm", "--no-deps", "--entrypoint", "sh", "web", "-c", "bundle exec ruby -e #{ruby.inspect}"],
        capture: false)
      code
    end

    private def load_sql_and_migrate(fresh : Bool) : Int32
      # schema.sql is tiny (extensions/base); the 64 tables come from the
      # timestamp migrations, which are idempotent via schema_migrations — safe
      # to re-run (only pending ones apply). On a fresh DB we also run
      # schema.sql; on an existing one we skip it (its statements would error).
      # Ruby uses string concatenation (not "#{}") on purpose: this snippet is
      # `.inspect`-wrapped into a shell arg, and inspect escapes `#{` → the
      # emitted Ruby would print it literally. `#{SENTINEL_TABLE}` here IS a
      # real Crystal interpolation (injects the table name at compile of the
      # command).
      ruby = String.build do |s|
        s << %{require "sequel"; require "sequel/extensions/migration"; }
        s << %{db = Sequel.connect(ENV["DATABASE_URL"]); }
        if fresh
          s << %{begin; db.run(File.read("db/schema.sql")); rescue e; STDERR.puts("schema.sql: " + e.message.to_s); end; }
          s << %{db.run("CREATE EXTENSION IF NOT EXISTS hstore") rescue nil; }
        end
        s << %{Sequel::Migrator.run(db, "db/migrate"); }
        s << %{puts("[db] tables=" + db.tables.count.to_s + " event_store=" + db.table_exists?(:#{SENTINEL_TABLE}).to_s)}
      end
      web_ruby(ruby)
    end

    private def init
      if schema_loaded?(flags.database)
        puts VoIPAppz::Colors.green("✔ #{flags.database} already initialized — applying any pending migrations")
        exit migrate_only
      end
      puts VoIPAppz::Colors.bold("Loading schema into #{flags.database} (fresh)…")
      code = load_sql_and_migrate(fresh: true)
      exit code unless code == 0
      puts VoIPAppz::Colors.green("✔ #{flags.database} initialized")
    end

    private def migrate
      exit migrate_only
    end

    private def migrate_only : Int32
      puts VoIPAppz::Colors.bold("Applying pending migrations to #{flags.database}…")
      load_sql_and_migrate(fresh: false)
    end

    # ---- reset (destructive) ----------------------------------------------

    private def reset
      db = flags.database
      unless flags.yes
        puts VoIPAppz::Colors.yellow("⚠ This DROPS and recreates the '#{db}' database — ALL data in it is lost.")
        print "Type the database name to confirm: "
        confirm = gets.try(&.strip)
        unless confirm == db
          puts "Aborted."
          exit 1
        end
      end

      # web/cable hold open connections to the DB; drop fails while they're up.
      puts VoIPAppz::Colors.bold("Stopping web + cable (open connections block DROP)…")
      VoIPAppz::Docker.compose(["stop", "web", "cable"], capture: true)

      puts VoIPAppz::Colors.bold("Dropping + recreating #{db}…")
      # terminate any stragglers, then drop/create from the `postgres` maintenance DB
      psql("postgres", "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='#{db}' AND pid<>pg_backend_pid()")
      code, out = psql("postgres", "DROP DATABASE IF EXISTS #{db}")
      unless code == 0
        STDERR.puts VoIPAppz::Colors.red("DROP failed: #{out}")
        exit 1
      end
      psql("postgres", "CREATE DATABASE #{db}")

      puts VoIPAppz::Colors.bold("Reloading schema…")
      code = load_sql_and_migrate(fresh: true)
      exit code unless code == 0

      puts VoIPAppz::Colors.bold("Restarting web + cable…")
      VoIPAppz::Docker.compose(["start", "web", "cable"], capture: true)
      puts VoIPAppz::Colors.green("✔ #{db} reset and reloaded")
    end
  end
end
