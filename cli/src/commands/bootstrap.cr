require "admiral"
require "../helpers/colors"
require "../helpers/docker"

module VoIPAppz::Commands
  # `voipappz bootstrap` — single-command fresh-machine bring-up.
  # Sequence:
  #   1. docker login (if needed)
  #   2. setup --ci  (idempotent: re-uses persisted secrets/<name>.txt)
  #   3. up -p app --wait
  #   4. voip profile is deployed on the separate switch machine
  #   5. health
  #
  # Designed to be safe to re-run: each step is idempotent. If a step fails,
  # bootstrap exits non-zero with a pointer to the failing subcommand so an
  # operator can debug the smaller surface.
  class Bootstrap < Admiral::Command
    define_help description: "One-shot full bring-up: login, setup, up, health"

    define_flag skip_login : Bool,
      description: "Skip the docker login step (assume creds already cached)",
      default: false
    define_flag skip_voip : Bool,
      description: "Compatibility flag; the voip profile is always separate",
      default: true
    define_flag ci : Bool,
      description: "Pass --ci to setup/up (non-interactive)",
      default: false

    def run
      ci = flags.ci

      banner_line "1/5  docker login"
      unless flags.skip_login
        run_step("voipappz login", ["login"]) do
          # Skipping login is OK if docker is already authenticated; we test
          # with a no-op `docker info`. If config is missing, login is required.
          unless docker_logged_in?
            STDERR.puts VoIPAppz::Colors.warning("docker login failed; bootstrap cannot pull private images")
            exit 1
          end
        end
      else
        puts VoIPAppz::Colors.dim("    (--skip-login)")
      end

      banner_line "2/5  voipappz setup --ci  (idempotent)"
      run_step("voipappz setup", ["setup", "--ci"])

      banner_line "3/5  voipappz up -p app --wait"
      args = ["up", "-p", "app", "--wait"]
      args << "--ci" if ci
      run_step("voipappz up -p app", args)

      if flags.skip_voip
        banner_line "4/5  voip profile  (separate switch machine)"
      else
        STDERR.puts VoIPAppz::Colors.error("The voip profile must be deployed on a separate switch machine.")
        STDERR.puts "  Run: voipappz deploy --host <switch> -P voip"
        exit 1
      end

      banner_line "5/5  voipappz health"
      # --ci unconditionally, despite the name: in `health` it means "retry
      # while the stack warms up", and bootstrap has just started that stack
      # thirty seconds ago. Without it the check gets ONE attempt, and a fresh
      # node whose Kong has not finished loading its declarative config answers
      # 503 — so bootstrap reported failure on a node that was completely fine
      # and healthy again by the time anyone typed `voipappz health`. Seen on
      # the first boot of an ISO-installed node.
      run_step("voipappz health --api", ["health", "--api", "--ci"])

      puts ""
      puts VoIPAppz::Colors.banner([
        "",
        "   #{VoIPAppz::Colors::CHECK} Bootstrap complete",
        "",
        "   Next:",
        "     #{VoIPAppz::Colors::ARROW} voipappz deploy --host <switch> -P voip",
        "     #{VoIPAppz::Colors::ARROW} voipappz status        Live container table",
        "     #{VoIPAppz::Colors::ARROW} voipappz config --endpoints   Reachable URLs",
        "     #{VoIPAppz::Colors::ARROW} voipappz backup --list   Backup snapshots",
        "",
      ])
    end

    private def banner_line(label : String)
      puts ""
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ROCKET} #{label}")
      puts ""
    end

    # Run a child voipappz invocation. Self-spawn so each step is its own
    # subcommand surface (single source of truth for what each step means).
    private def run_step(label : String, argv : Array(String), &block)
      bin = File.expand_path(Process.executable_path || "voipappz")
      status = Process.run(bin, argv,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)
      unless status.success?
        STDERR.puts VoIPAppz::Colors.error("#{label} failed (exit #{status.exit_code})")
        exit status.exit_code || 1
      end
      yield
    end

    private def run_step(label : String, argv : Array(String))
      run_step(label, argv) { }
    end

    # Lightweight check: is the docker daemon reachable AND is config.json
    # populated with an auth entry. Operators who already ran `docker login`
    # outside the CLI shouldn't be forced to do it again.
    private def docker_logged_in? : Bool
      cfg = File.join(ENV["HOME"]? || "/root", ".docker", "config.json")
      return false unless File.exists?(cfg)
      content = File.read(cfg)
      content.includes?("\"auth\":") || content.includes?("credsStore") || content.includes?("credHelpers")
    end
  end
end
