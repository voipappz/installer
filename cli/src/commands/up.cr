require "admiral"
require "http/client"
require "../helpers/docker"
require "../helpers/colors"
require "../helpers/services"
require "../helpers/wait"
require "../helpers/secrets"
require "../helpers/bao"
require "../helpers/bao_sync"

module VoIPAppz::Commands
  class Up < Admiral::Command
    define_help description: "Start services (by profile or all)"

    define_flag profile : String,
      description: "Profile to start: app, voip, storage (default: app)",
      default: "app",
      short: p
    define_flag service : String,
      description: "Start a single service by name (e.g. kamailio)",
      default: ""
    define_flag wait : Bool,
      description: "Wait for services to be healthy before returning",
      default: false,
      short: w
    define_flag ci : Bool,
      description: "Use CI-optimized wait times",
      default: false
    define_flag recreate : Bool,
      description: "Force-recreate containers (pick up new env/config)",
      default: false

    def run
      # Enable CI mode for docker helper (uses json-file logging override)
      VoIPAppz::Docker.ci_mode = flags.ci
      if flags.ci
        ci_file = File.join(VoIPAppz::Docker.project_dir, VoIPAppz::Docker::CI_OVERRIDE)
        if File.exists?(ci_file)
          puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::GEAR} CI mode: using #{VoIPAppz::Docker::CI_OVERRIDE} override")
        else
          puts VoIPAppz::Colors.warning("CI mode: #{ci_file} not found, syslog may fail")
        end
      end

      warn_unless_x86_64_v2

      # Ensure .env exists with secrets
      ensure_env

      unless flags.service.empty?
        puts VoIPAppz::Colors.step(1, "Starting service: #{flags.service}")
        VoIPAppz::Docker.compose!(["up", "-d", "--remove-orphans"] + recreate_args + [flags.service])
        puts VoIPAppz::Colors.success("#{flags.service} started")
        return
      end

      profile = flags.profile

      case profile
      when "app"
        start_app
      when "voip"
        start_voip
      when "storage"
        start_storage
      when "all"
        STDERR.puts VoIPAppz::Colors.error("The app and voip profiles must run on separate machines.")
        STDERR.puts "  App/ingress machine: voipappz up -p app --wait"
        STDERR.puts "  VoIP/egress machine: voipappz up -p voip --wait"
        exit 1
      else
        STDERR.puts VoIPAppz::Colors.error("Unknown profile: #{profile}")
        STDERR.puts "  Valid profiles: app, voip, storage"
        exit 1
      end
    end

    # `createbuckets` is a one-shot init container, not in the Services
    # catalog (which is the user-facing service list) but still needed
    # at startup to provision MinIO buckets.
    APP_EXTRAS = ["createbuckets", "db-init"]

    # The app plane needs the storage plane: `web` writes recordings to MinIO
    # over S3, so bringing up app without storage yields a running-but-broken
    # API. minio therefore lives in the `storage` profile (matching compose)
    # and is pulled in here rather than being mislabelled as an app service.
    private def app_services : Array(String)
      VoIPAppz::Services.names_for("app") +
        VoIPAppz::Services.names_for("storage") + APP_EXTRAS
    end

    private def voip_services : Array(String)
      VoIPAppz::Services.names_for("voip")
    end

    private def storage_services : Array(String)
      VoIPAppz::Services.names_for("storage") + ["createbuckets"]
    end

    # `--force-recreate` when the operator wants new env/bind-mounted config
    # pushed into already-running containers (compose only auto-recreates on a
    # changed config hash, which bind-mount file edits don't alter).
    private def recreate_args : Array(String)
      flags.recreate ? ["--force-recreate"] : [] of String
    end

    # postgres tracks the moving `pgedge` tag (rebuilt from the va-voipbox-postgres
    # edge branch), so a cached image goes stale. Pull it before app start so
    # installs/upgrades land on the current edge build. Best-effort: an offline
    # box (no registry) still boots on the cached image.
    private def pull_postgres
      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::NET} Pulling latest postgres (edge) image...")
      VoIPAppz::Docker.compose(["pull", "postgres"])
    end

    private def start_app
      puts VoIPAppz::Colors.step(1, "Starting application services... #{VoIPAppz::Colors::NET}")
      pull_postgres
      VoIPAppz::Docker.compose!(["up", "-d", "--remove-orphans"] + recreate_args + app_services)
      puts VoIPAppz::Colors.success("Application services started")
      wait_for_app if flags.wait
      bootstrap_bao
    end

    private def start_voip
      puts VoIPAppz::Colors.step(1, "Starting VoIP services... #{VoIPAppz::Colors::PHONE}")
      VoIPAppz::Docker.compose!(["up", "-d", "--remove-orphans"] + recreate_args + voip_services)
      puts VoIPAppz::Colors.success("VoIP services started")
      wait_for_voip if flags.wait
    end

    # Storage on its own — mostly for recovering a node whose MinIO fell over
    # without cycling the whole app plane. `up -p app` already includes these.
    private def start_storage
      puts VoIPAppz::Colors.step(1, "Starting storage services... #{VoIPAppz::Colors::BOX}")
      VoIPAppz::Docker.compose!(["up", "-d", "--remove-orphans"] + recreate_args + storage_services)
      puts VoIPAppz::Colors.success("Storage services started")
      VoIPAppz::Wait.for_minio if flags.wait
    end

    private def start_all
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ROCKET} Starting VoIPAppz")
      puts ""

      puts VoIPAppz::Colors.step(1, "Starting application services #{VoIPAppz::Colors::NET} (#{app_services.join(", ")})...")
      pull_postgres
      VoIPAppz::Docker.compose!(["up", "-d", "--remove-orphans"] + recreate_args + app_services)
      if flags.wait
        wait_for_app
      else
        puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::CLOCK} Waiting for applications to be ready...")
        sleep 15.seconds
      end

      bootstrap_bao

      puts VoIPAppz::Colors.step(2, "Starting VoIP services #{VoIPAppz::Colors::PHONE} (#{voip_services.join(", ")})...")
      VoIPAppz::Docker.compose!(["up", "-d", "--remove-orphans"] + recreate_args + voip_services)
      wait_for_voip if flags.wait

      print_banner
    end

    # OpenBao comes up SEALED on every (re)start. Since it's part of the app
    # profile and idempotent, bring it into service automatically after the app
    # services are up: init on a truly fresh box (writes the bootstrap unseal
    # key + root token to secrets/openbao_*.txt), otherwise just re-unseal from
    # the stored key. NEVER fails `up` — a Bao that isn't ready yet just prints
    # a hint.
    #
    # Bao is the source of truth (2026-07-08): once unsealed, sync disk ↔ Bao.
    #   * empty Bao  → SEED it from the setup-generated disk files (first run).
    #   * populated  → DUMP it to disk, regenerating .env + config/va.yaml.
    # Seeding only writes to an EMPTY Bao, so a stale .env can never clobber a
    # populated store; a populated Bao always wins.
    private def bootstrap_bao
      st = VoIPAppz::Bao.status
      return unless st.running # openbao not in this compose / not up yet

      if st.sealed || !st.initialized
        ok, msg = VoIPAppz::Bao.init
        unless ok
          puts VoIPAppz::Colors.warning("openbao: #{msg} — run 'voipappz secrets --bao-init' manually")
          return
        end
        ok, msg = VoIPAppz::Bao.unseal
        unless ok
          puts VoIPAppz::Colors.warning("openbao: #{msg} — run 'voipappz secrets --bao-init' manually")
          return
        end
      end
      VoIPAppz::Bao.enable_kv # idempotent — ensures the va/ kv mount exists
      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::KEY} openbao unsealed (secrets store ready)")

      project_dir = VoIPAppz::Docker.project_dir
      if VoIPAppz::BaoSync.populated?
        res = VoIPAppz::BaoSync.dump(project_dir)
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::ARROW} openbao → regenerated .env + config/va.yaml (#{res.keys} keys, #{res.files.size} files)")
      else
        res = VoIPAppz::BaoSync.push(project_dir)
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::ARROW} seeded openbao from disk (#{res.keys} keys, #{res.files.size} files) — now source of truth")
      end
    rescue ex
      # Bao sync must never fail `up` — the stack runs off the on-disk files.
      puts VoIPAppz::Colors.warning("openbao sync skipped: #{ex.message}")
    end


    # The x86-64-v2 instruction set, as glibc's ELF marker requires it.
    X86_64_V2_FLAGS = %w[cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3]

    # Not every image on this stack runs on every CPU, and the failure does not
    # say so. `quay.io/minio/minio` is RHEL 9.6, whose libc.so.6 carries
    # `x86 ISA needed: x86-64-v2` — on a CPU without it EVERY binary in that
    # image aborts with "Fatal glibc error: CPU does not support x86-64-v2",
    # including the `curl` its healthcheck runs. minio never goes healthy, and
    # because createbuckets and db-init both wait on it, all compose reports is
    # "dependency failed to start: container va-minio is unhealthy" — the
    # symptom, three services away from the cause. That cost a full boot test
    # here before anyone thought to look at the CPU.
    #
    # Real hardware has had x86-64-v2 since Nehalem, 2009. What has not is a VM
    # told to present a generic processor: qemu's default `qemu64` model, or a
    # hypervisor pinned to an old compatibility level so guests can live-migrate
    # onto ancient hosts. Both are one setting away from working.
    #
    # A warning, not a refusal: everything except object storage runs fine, and
    # a node that will not start at all is worse than one that says what is
    # wrong with it.
    private def warn_unless_x86_64_v2
      return unless File.exists?("/proc/cpuinfo")
      flags_line = File.read_lines("/proc/cpuinfo").find(&.starts_with?("flags"))
      return unless flags_line
      have = flags_line.split(':', 2)[1].split
      missing = X86_64_V2_FLAGS.reject { |f| have.includes?(f) }
      return if missing.empty?

      puts VoIPAppz::Colors.warning(
        "This CPU lacks x86-64-v2 (missing: #{missing.join(", ")})")
      puts VoIPAppz::Colors.dim(
        "    minio is RHEL9-based and every binary in it will abort; expect")
      puts VoIPAppz::Colors.dim(
        "    \"container va-minio is unhealthy\". On a VM, present the host CPU")
      puts VoIPAppz::Colors.dim(
        "    (qemu: -cpu host; VMware/Hyper-V: raise the compatibility level).")
    end

    # Ensure .env exists with secrets — generate if missing
    private def ensure_env
      project_dir = VoIPAppz::Docker.project_dir
      env_path = File.join(project_dir, ".env")
      return if File.exists?(env_path) && File.size(env_path) > 0

      puts VoIPAppz::Colors.warning("No .env found — generating secrets...")
      secrets = VoIPAppz::SecretsHelper.generate_all_hash
      config = VoIPAppz::VaConfig.load(project_dir)
      VoIPAppz::VaConfig.write_env(config, project_dir, secrets)
      puts VoIPAppz::Colors.success(".env generated with secrets")
    end

    private def wait_for_app
      VoIPAppz::Wait.for_app_profile(ci: flags.ci)
    end

    private def wait_for_voip
      VoIPAppz::Wait.for_voip_profile(ci: flags.ci)
    end

    private def print_banner
      puts ""
      puts VoIPAppz::Colors.banner([
        "",
        "   #{VoIPAppz::Colors::ROCKET} VoIPAppz node-lite started",
        "",
        "   #{VoIPAppz::Colors::PHONE}  SIP:        localhost:5060",
        "   #{VoIPAppz::Colors::NET}  Node HTTP:  http://localhost:4000",
        "   #{VoIPAppz::Colors::BOX}  MinIO:      http://localhost:9000",
        "   #{VoIPAppz::Colors::BOX}  MQTT:       localhost:1883",
        "",
      ])
      puts ""
    end
  end
end
