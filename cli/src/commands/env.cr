require "admiral"
require "../helpers/colors"
require "../helpers/node_env"

module VoIPAppz::Commands
  # Environment-variable reference + live status. The CLI auto-loads ./.env at
  # startup (process env wins), so this shows the effective configuration the
  # commands will actually use. Secrets are masked.
  class Env < Admiral::Command
    define_help description: "Show the env vars the CLI honors and which are set"

    # ── --export: va.yaml -> the voip container's environment ──
    #
    # The container parses its mounted va.yaml at start (an s6 oneshot runs
    # this) instead of having every value restated as `-e` by whoever launched
    # it. One file per node is the only per-node input; see VoIPAppz::NodeEnv
    # for what is derived and what deliberately is not.
    define_flag export : Bool,
      description: "Print the voip-plane environment derived from va.yaml (KEY=value)",
      default: false
    define_flag file : String,
      description: "va.yaml to read (default: $VA_PATH, else /opt/va.yaml)",
      default: ""
    define_flag s6 : String,
      description: "Write one file per key into this s6 container_environment dir",
      default: ""

    # {var, what it connects, secret?}
    VARS = [
      {"— connection —", "", false},
      {"VA_API_URL", "cloud API (FS boot gate, dialplan, admin commands)", false},
      {"VA_API_AUTHORIZATION", "root Basic authorization for `node register` (environment only)", true},
      {"VA_NATS_URL", "NATS bus URL (node/cable; nats://nats:4222 on hosts)", true},
      {"VA_NATS_HOST", "cloud NATS IP for the compose `nats` extra_host", false},
      {"VA_ADMIN_URL", "admin API base (bare domain, e.g. https://cloud.voipappz.io)", false},
      {"VA_ADMIN_USER", "admin username for basic auth (email/uuid/username)", false},
      {"VA_ADMIN_PASSWORD", "admin password — base64'd with user into Basic auth", true},
      {"— identity & network —", "", false},
      {"VA_NODE_UUID", "this node's UUID (cloud-provisioned; in dialplan URL)", false},
      {"VA_APP_INTERNAL_IP_ADDRESS", "LAN bind IP (kamailio/FS)", false},
      {"VA_APP_EXTERNAL_IP_ADDRESS", "public on-NIC IP (kamailio binds + advertises)", false},
      # Container overrides. These point a command at a container other than
      # the one role-based resolution would pick — a second stack beside the
      # live one, a renamed container, or va-crystal's test stack. The rule is
      # VA_<SERVICE>_CONTAINER for any service.
      #
      # The defaults all read va-voip on a current node: kamailio, FreeSWITCH
      # and the node share ONE container since the voip profile was merged.
      # On a node still running the three-container layout they resolve to
      # va-egress / va-voip / va-node as before.
      {"— container overrides —", "", false},
      {"VA_FREESWITCH_CONTAINER", "container holding FreeSWITCH (default: va-voip)", false},
      {"VA_NODE_CONTAINER", "container holding the crystal node (default: va-voip)", false},
      {"VA_KAMAILIO_EGRESS_CONTAINER", "container holding the egress SBC (default: va-voip)", false},
      {"VA_KAMAILIO_INGRESS_CONTAINER", "container holding the ingress forwarder (default: va-ingress)", false},
      {"— stack & data —", "", false},
      {"COMPOSE_PROJECT_NAME", "docker compose project (deployed hosts use `va`)", false},
      {"VA_DATABASE_URL", "PostgreSQL URL", true},
      {"VA_POSTGRES_PASSWORD", "PostgreSQL password", true},
      {"VA_FREESWITCH_PASSWORD", "FS ESL password", true},
      {"VA_S3_ENDPOINT", "S3/MinIO endpoint for recordings", false},
      {"VA_S3_KEY", "S3 access key", true},
      {"VA_S3_SECRET", "S3 secret key", true},
    ]

    def run
      return export! if flags.export || !flags.s6.empty?

      puts VoIPAppz::Colors.header("Environment configuration")
      puts VoIPAppz::Colors.dim("./.env is auto-loaded at startup; real process env overrides it.")
      puts VoIPAppz::Colors.dim("Override per run:  VA_API_URL=https://cloud.voipappz.io voipappz <cmd>")
      puts ""
      VARS.each do |(name, what, secret)|
        if what.empty?
          puts VoIPAppz::Colors.bold("  #{name}")
          next
        end
        val = ENV[name]?
        state = if val.nil? || val.empty?
                  VoIPAppz::Colors.dim("(unset)")
                elsif secret
                  VoIPAppz::Colors.green(mask(val))
                else
                  VoIPAppz::Colors.green(val[0, 48])
                end
        puts "  #{name.ljust(28)} #{state}"
        puts "  #{" ".ljust(28)} #{VoIPAppz::Colors.dim(what)}"
      end
      puts ""
      puts VoIPAppz::Colors.dim("Secrets files live under ./secrets/ (see `voipappz secrets`).")
    end

    private def export!
      path = flags.file
      path = ENV["VA_PATH"]? || "/opt/va.yaml" if path.empty?

      boot = !flags.s6.empty?

      unless File.exists?(path)
        refuse(path, ["no file at #{path} — mount the node's va.yaml there (docker -v /path/va.yaml:#{path}), or create one: voipappz setup"])
      end

      config = begin
        VoIPAppz::DeployConfig.load(path)
      rescue ex : YAML::ParseException
        refuse(path, ["#{path}:#{ex.line_number}:#{ex.column_number}: #{ex.message}"])
      rescue ex
        refuse(path, ["#{path}: #{ex.message}"])
      end
      env = VoIPAppz::NodeEnv.from(config, va_path: path)

      problems = VoIPAppz::NodeEnv.problems(env, boot: boot)
      refuse(path, problems) unless problems.empty?

      if (dir = flags.s6) && !dir.empty?
        write_s6(env, dir)
      else
        env.to_a.sort_by(&.[0]).each { |k, v| puts "#{k}=#{v}" }
      end
    end

    # One report, every problem, exit 1. At boot (--s6) that halts the
    # container before kamailio, FreeSWITCH or the node start on a broken
    # environment; by hand it is the same message.
    private def refuse(path : String, problems : Array(String)) : NoReturn
      STDERR.puts VoIPAppz::Colors.red("va-env: #{path} cannot configure this node — #{problems.size} problem(s):")
      problems.each { |p| STDERR.puts "  #{VoIPAppz::Colors.red("✗")} #{p}" }
      STDERR.puts VoIPAppz::Colors.dim("  fix the file, then restart the container (or: voipappz env --export --file #{path} to re-check)")
      exit 1
    end

    # THE FILE FILLS WHAT IS UNSET, AND NOTHING MORE.
    #
    # s6 seeds container_environment from the container's own environment
    # before any oneshot runs, so a key already sitting here came from `docker
    # -e` or compose — someone said it explicitly for THIS run, and va.yaml
    # must not overrule that. (It is also why the image can no longer bake
    # VA_*_IP_ADDRESS_STR as ENV: s6 seeds those the same way, and a baked
    # default is then indistinguishable from a deliberate override.)
    private def write_s6(env : Hash(String, String), dir : String) : Nil
      Dir.mkdir_p(dir)
      wrote = [] of String
      kept = [] of String

      env.to_a.sort_by(&.[0]).each do |key, value|
        next if value.empty?
        target = File.join(dir, key)
        if File.exists?(target) && !File.read(target).strip.empty?
          kept << key
          next
        end
        # No trailing newline: s6-envdir strips one, but nothing else that
        # reads this directory promises to.
        File.write(target, value)
        wrote << key
      end

      puts "va-env: #{wrote.size} from va.yaml (#{wrote.join(" ")})"
      puts "va-env: #{kept.size} already set, left alone (#{kept.join(" ")})" unless kept.empty?
    end

    private def mask(val : String) : String
      return "set" if val.size < 8
      "#{val[0, 4]}…#{val[-2, 2]} (#{val.size} chars)"
    end
  end
end
