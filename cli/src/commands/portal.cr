require "admiral"
require "json"
require "../helpers/colors"
require "../helpers/portal"
require "../helpers/kamal"
require "../helpers/env_file"

module VoIPAppz::Commands
  # `voipappz portal` — the user-facing app, github.com/voipappz/app.
  #
  # This replaces the app repo's own Makefile. Everything runs in Docker, as
  # that file insisted: no host node, npm, ruby or kamal is needed for any verb
  # here, which is what let a portal contributor start from a bare clone.
  #
  # The portal is NOT the mothership stack. Its compose project, .env and kamal
  # destinations are its own, so nothing here goes through VoIPAppz::Docker —
  # see the note in helpers/portal.cr.
  class Portal < Admiral::Command
    define_help description: "The portal app (github.com/voipappz/app): run it, test it, deploy it"

    register_sub_command dev, type: Dev
    register_sub_command up, type: Up
    register_sub_command down, type: Down
    register_sub_command logs, type: Logs
    register_sub_command check, type: Check
    register_sub_command verify, type: Verify
    register_sub_command status, type: Status
    register_sub_command build, type: Build
    register_sub_command lint, type: Lint
    register_sub_command unit, type: Unit
    register_sub_command test, type: Test
    register_sub_command prod, type: Prod
    register_sub_command deploy, type: Deploy
    register_sub_command ship, type: Ship
    register_sub_command env, type: Env
    register_sub_command scaffold, type: Scaffold
    register_sub_command ci, type: Ci

    def run
      puts help
    end

    # ---------------------------------------------------------------- running

    class Dev < Admiral::Command
      define_help description: "Run the app in Docker (Vite :4200 + portal :4001), attached logs"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        Check.report(dir)
        VoIPAppz::Portal.compose!(dir, ["up", "-d", "react-app", "elixir", "chrome-ext"])
        puts "portal → #{VoIPAppz::Portal::PORTAL} · Vite → #{VoIPAppz::Portal::WEB_APP} " \
             "(proxies /api → mothership #{VoIPAppz::Portal.mothership(dir)})"
        puts "Ctrl-C detaches; stack keeps running"
        VoIPAppz::Portal.compose(dir, ["logs", "-f", "react-app", "elixir"])
      end
    end

    class Up < Admiral::Command
      define_help description: "Start the full Docker stack (web + portal + extension), detached"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        VoIPAppz::Portal.compose!(dir, ["up", "-d", "react-app", "elixir", "chrome-ext"])
        puts "web → #{VoIPAppz::Portal::WEB_APP}   portal → #{VoIPAppz::Portal::PORTAL}"
      end
    end

    class Down < Admiral::Command
      define_help description: "Stop all portal services"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        VoIPAppz::Portal.compose!(VoIPAppz::Portal.dir!(flags.path), ["down", "--remove-orphans"])
      end
    end

    class Logs < Admiral::Command
      define_help description: "Follow the portal logs"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""
      define_argument service : String, description: "Service to follow (default: react-app)"

      def run
        service = arguments.service || "react-app"
        VoIPAppz::Portal.compose(VoIPAppz::Portal.dir!(flags.path), ["logs", "-f", service])
      end
    end

    class Prod < Admiral::Command
      define_help description: "Build + run the production image on this box (:8000)"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""
      define_flag down : Bool, description: "Stop it instead", default: false

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        if flags.down
          VoIPAppz::Portal.compose!(dir, ["--profile", "prod", "down", "production"])
          return
        end

        VoIPAppz::Portal.compose!(dir, ["--profile", "prod", "build", "production"])
        VoIPAppz::Portal.compose!(dir, ["--profile", "prod", "up", "-d", "production"])

        print "waiting for boot..."
        30.times do
          break if VoIPAppz::Portal.http_code("http://localhost:8000/test", 2) == "200"
          sleep 1.second
        end
        puts ""
        {"/" => "/", "/test" => "/test", "/health" => "/health"}.each do |label, path|
          printf("  %-7s → %s\n", label, VoIPAppz::Portal.http_code("http://localhost:8000#{path}"))
        end
        puts "production → http://localhost:8000  (env from .env; recreate to re-read)"
      end
    end

    # ---------------------------------------------------------------- checks

    class Check < Admiral::Command
      define_help description: "Verify the mothership (MOTHERSHIP_URL) is reachable"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        Check.report(VoIPAppz::Portal.dir!(flags.path))
      end

      def self.report(dir : String) : Nil
        mothership = VoIPAppz::Portal.mothership(dir)
        puts "==> Mothership (override: VITE_API_TARGET / MOTHERSHIP_URL in .env)"
        code = VoIPAppz::Portal.http_code("#{mothership}/tasks/customer_portal_data")
        state = code.starts_with?("2") || code.starts_with?("3") || code.starts_with?("4") ?
                VoIPAppz::Colors.green("OK (#{code})") :
                VoIPAppz::Colors.red("UNREACHABLE (#{code}) — set MOTHERSHIP_URL in .env")
        printf("  %-11s %-34s %s\n", "mothership", mothership, state)
      end
    end

    class Verify < Admiral::Command
      define_help description: "Health check: the portal, Vite, and the /health dependency report"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        puts "==> Services"
        # /health/alive, not /test — that was the Deno server's liveness route.
        probe("portal", "#{VoIPAppz::Portal::PORTAL}/health/alive")
        probe("web/vite", "#{VoIPAppz::Portal::WEB_APP}/")

        puts "==> Dependencies (reported by #{VoIPAppz::Portal::PORTAL}/health)"
        body = VoIPAppz::Portal.get("#{VoIPAppz::Portal::PORTAL}/health")
        if body.nil? || body.empty?
          puts "  health endpoint unreachable"
          return
        end

        # JSON::Any, where the Makefile shelled out to an inline python3 —
        # one less interpreter this repo needs installed to answer a question.
        begin
          doc = JSON.parse(body)
          if checks = doc["checks"]?.try(&.as_h?)
            checks.each do |name, value|
              status = value["status"]?.try(&.as_s?) || "?"
              detail = value["detail"]?.try(&.as_s?)
              printf("  %-9s %-5s %s\n", name, status.upcase, detail ? "(#{detail})" : "")
            end
          end
          printf("  %-9s %s\n", "overall", (doc["status"]?.try(&.as_s?) || "?").upcase)
        rescue JSON::ParseException
          puts "  health endpoint returned no JSON"
        end
      end

      private def probe(label : String, url : String)
        printf("  %-9s %-30s ", label, url)
        puts VoIPAppz::Portal.http_code(url).starts_with?("2") ? "OK" : "DOWN"
      end
    end

    class Status < Admiral::Command
      define_help description: "Local git + production health + deployed version"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        puts "=== Local git ==="
        Process.run("git", ["log", "--oneline", "-1"], chdir: dir,
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        Process.run("git", ["status", "-sb"], chdir: dir,
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        puts ""

        prod = VoIPAppz::Portal.prod_url(dir)
        if prod.empty?
          puts "=== Production: PROD_URL not set (skip) — set PROD_URL in .env ==="
          return
        end

        puts "=== Production (#{prod}) ==="
        puts "GET /      → #{VoIPAppz::Portal.http_code("#{prod}/")}"
        puts "GET /health/alive → #{VoIPAppz::Portal.http_code("#{prod}/health/alive")}"
        puts "GET /health/ready → #{VoIPAppz::Portal.http_code("#{prod}/health/ready")}"
        puts "=== Deployed version ==="
        puts deployed_version(prod) || "(not found)"
      end

      # Scrape the version out of the served bundle: find the first asset the
      # SPA shell loads, fetch it, and read the stamp deploy.yml baked in.
      #
      # The Makefile hardcoded `2026\.` — that stops finding anything on 1 Jan.
      # VITE_APP_VERSION is %Y.%m.%d-<short-sha>, so match the shape, not a year.
      private def deployed_version(prod : String) : String?
        shell = VoIPAppz::Portal.get("#{prod}/")
        return nil unless shell
        asset = shell.match(/src="(\/assets\/[^"]+\.js)"/).try(&.[1])
        return nil unless asset
        bundle = VoIPAppz::Portal.get("#{prod}#{asset}", 20)
        return nil unless bundle
        bundle.match(/\d{4}\.\d{2}\.\d{2}-[a-f0-9]+/).try(&.[0])
      end
    end

    # ---------------------------------------------------------------- build & test

    class Build < Admiral::Command
      define_help description: "Production build → dist/ (in Docker)"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        VoIPAppz::Portal.npm!(VoIPAppz::Portal.dir!(flags.path), "build")
      end
    end

    class Lint < Admiral::Command
      define_help description: "ESLint (in Docker)"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        VoIPAppz::Portal.npm!(VoIPAppz::Portal.dir!(flags.path), "lint")
      end
    end

    class Unit < Admiral::Command
      define_help description: "Vitest unit tests, one-shot (in Docker)"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        VoIPAppz::Portal.npm!(VoIPAppz::Portal.dir!(flags.path), "test:run")
      end
    end

    class Test < Admiral::Command
      define_help description: "Playwright E2E in Docker (needs the app running — portal up)"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""
      define_flag crystal : Bool,
        description: "Instead: the Crystal mock → DuckDB → health/dashboard pipeline",
        default: false

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        if flags.crystal
          # The script directly, not `npm run test:crystal` — going through npm
          # needs a host node, which is the one thing every other verb avoids.
          status = Process.run("bash", ["scripts/test-crystal-pipeline.sh"], chdir: dir,
            output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
          exit status.exit_code unless status.success?
          return
        end
        VoIPAppz::Portal.compose!(dir, ["--profile", "test", "run", "--rm", "e2e"])
      end
    end

    class Ci < Admiral::Command
      define_help description: "Run the GitHub Actions workflow locally with act"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""
      define_flag api : Bool, description: "Only the portal/cable job", default: false

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        status = Process.run("scripts/ci-local.sh", [flags.api ? "api" : "all"], chdir: dir,
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        exit status.exit_code unless status.success?
      end
    end

    # ---------------------------------------------------------------- setup

    class Env < Admiral::Command
      define_help description: "Create .env (never overwrites an existing one)"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        env = File.join(dir, ".env")
        if File.exists?(env)
          puts ".env exists — leaving it alone. Mothership: #{VoIPAppz::Portal.mothership(dir)}"
        else
          example = File.join(dir, ".env.example")
          unless File.exists?(example)
            STDERR.puts VoIPAppz::Colors.red("no .env.example in #{dir}")
            exit 1
          end
          File.copy(example, env)
          puts "wrote .env — set MOTHERSHIP_URL to point at your tenant"
        end
      end
    end

    class Scaffold < Admiral::Command
      define_help description: "Scaffold a feature module: portal scaffold Foo [--endpoint /api/foos]"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""
      define_argument name : String, description: "Module name, e.g. Foo", required: true
      define_flag endpoint : String, description: "API endpoint, e.g. /api/foos", default: ""

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        # --user: the scaffolder writes into the repo mount and the container is
        # root, so without it the new files land root-owned and you need sudo to
        # edit or delete your own scaffold. Safe here (unlike build/lint/unit)
        # because this only writes source files — it never touches the
        # node_modules volume.
        VoIPAppz::Portal.compose!(dir, [
          "run", "--rm", "--no-deps", "--user", VoIPAppz::Portal.user_group,
          "react-app", "node", "scripts/new-module.mjs", arguments.name, flags.endpoint,
        ])
      end
    end

    # ---------------------------------------------------------------- deploy

    class Deploy < Admiral::Command
      define_help description: "Build image, push to registry, swap the container on production"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""
      define_flag dest : String,
        description: "Destination — config/portal/deploy.<dest>.yml (empty = config/portal/deploy.yml)",
        short: d,
        default: ""
      define_flag print : Bool,
        description: "Print the exact commands and change nothing",
        default: false

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        Deploy.run_deploy(dir, flags.dest, flags.print)
      end

      def self.run_deploy(dir : String, dest : String, print_only : Bool) : Nil
        destination =
          begin
            VoIPAppz::Portal.destination(dest)
          rescue ex : VoIPAppz::Portal::NotFound
            STDERR.puts VoIPAppz::Colors.red(ex.message.to_s)
            exit 1
          end

        health = VoIPAppz::Portal.healthcheck_url(dir, destination)
        dest_args = dest.empty? ? [] of String : ["-d", dest]
        config = dest.empty? ? "config/deploy.yml" : "config/deploy.#{dest}.yml"

        stop_cmd = VoIPAppz::Kamal.command(dir, ["app", "stop"] + dest_args, health,
          conf_dir: VoIPAppz::Portal.conf_dir)
        deploy_cmd = VoIPAppz::Kamal.command(dir, ["deploy"] + dest_args, health,
          conf_dir: VoIPAppz::Portal.conf_dir)

        if print_only
          puts "==> kamal deploy #{dest_args.join(" ")}  (#{config})"
          puts "    secrets:     #{VoIPAppz::Portal.secret_files(dest).map { |f| f.sub(File.dirname(VoIPAppz::Portal.conf_dir) + "/", "") }.join(", ")}"
          puts "    stop_first:  #{destination.stop_first}"
          puts "    healthcheck: #{health.empty? ? "(unset — the post-deploy hook skips its probes)" : health}"
          puts ""
          puts stop_cmd.join(" ") if destination.stop_first
          puts deploy_cmd.join(" ")
          return
        end

        VoIPAppz::Portal.check_secrets!(dest)
        # Into OUR env, so the child inherits them by name — `-e KEY`, never
        # `-e KEY=value`, which would put the registry PAT in the process table.
        VoIPAppz::EnvFile.export!(VoIPAppz::Portal.secrets(dest))
        ENV["KAMAL_HEALTHCHECK_URL"] = health unless health.empty?

        puts "==> kamal deploy #{dest_args.join(" ")}  (#{config})"

        if destination.stop_first
          puts "==> #{dest} publishes a fixed port with proxy:false — stopping the old container first (brief downtime)"
          # Deliberately unchecked: there may be nothing to stop, and that is
          # not a failure. The deploy below is what must succeed.
          Process.run(stop_cmd[0], stop_cmd[1..],
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        end

        status = Process.run(deploy_cmd[0], deploy_cmd[1..],
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        unless status.success?
          STDERR.puts VoIPAppz::Colors.red("kamal deploy failed")
          exit status.exit_code
        end
        puts VoIPAppz::Colors.green("Deployed.")
      end
    end

    class Ship < Admiral::Command
      define_help description: "git push + deploy in one shot"
      define_flag path : String,
        description: "Path to the portal (default: the ../app sibling, or $VA_PORTAL_DIR)",
        default: ""
      define_flag dest : String, description: "Destination", short: d, default: ""
      define_flag print : Bool, description: "Print the commands and change nothing", default: false

      def run
        dir = VoIPAppz::Portal.dir!(flags.path)
        unless flags.print
          status = Process.run("git", ["push"], chdir: dir,
            output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
          exit status.exit_code unless status.success?
        end
        Deploy.run_deploy(dir, flags.dest, flags.print)
      end
    end
  end
end
