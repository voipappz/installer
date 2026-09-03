require "admiral"
require "file_utils"
require "../helpers/colors"
require "../helpers/app_deploy"
require "../helpers/deploy_destination"
require "../helpers/va_config"

module VoIPAppz::Commands
  # `voipappz app` — scaffold and deploy a CUSTOMER application.
  #
  # The app is a separate repo (voipappz/app, a GitHub template): React + Vite
  # frontend and a Deno BFF, built into ONE production image that serves both.
  # It is deliberately not part of this stack — it has its own release cadence
  # and its own registry, and the only wire into the platform is the node's
  # Cable endpoint. The CLI's job is to remove the two manual steps: knowing
  # the template exists, and hand-writing a Kamal destination per host.
  #
  #   voipappz app new <name>          # scaffold a tenant app
  #   voipappz app deploy -d <dest>    # generate the Kamal config + deploy
  class App < Admiral::Command
    define_help description: "Scaffold and deploy a customer application"

    register_sub_command new, type: New
    register_sub_command deploy, type: Deploy

    def run
      puts help
    end

    TEMPLATE_REPO = "https://github.com/voipappz/app.git"
    # Pin the branch. The template repo's working branches have at times had the
    # entire frontend removed from the tree, and cloning whatever HEAD happens
    # to point at would scaffold a broken app.
    TEMPLATE_REF = "main"

    class New < Admiral::Command
      define_help description: "Scaffold a customer app from the voipappz/app template"

      define_argument name : String,
        description: "Directory (and app) name to create",
        required: true

      define_flag mothership : String,
        description: "Tenant API base URL baked into the app (defaults to organization.domain from config/va.yaml)",
        default: ""

      define_flag ref : String,
        description: "Template branch/tag to scaffold from",
        default: TEMPLATE_REF

      def run
        target = File.expand_path(arguments.name)
        if Dir.exists?(target)
          STDERR.puts VoIPAppz::Colors.red("#{target} already exists — refusing to overwrite.")
          exit 1
        end

        mothership = flags.mothership
        if mothership.empty?
          config = VoIPAppz::VaConfig.load(Dir.current)
          mothership = VoIPAppz::AppDeploy.mothership_url(config)
        end

        puts VoIPAppz::Colors.bold("Scaffolding #{File.basename(target)}")
        puts "  template: #{TEMPLATE_REPO} (#{flags.ref})"
        puts "  mothership: #{mothership.empty? ? VoIPAppz::Colors.dim("unset — edit .env before `make dev`") : mothership}"
        puts ""

        unless clone(target)
          STDERR.puts ""
          STDERR.puts VoIPAppz::Colors.red("Could not clone the template.")
          STDERR.puts VoIPAppz::Colors.dim("  The repo is private — authenticate first (`gh auth login`), or ask")
          STDERR.puts VoIPAppz::Colors.dim("  for access to voipappz/app.")
          exit 1
        end

        # The customer owns their history from here — this is a template, not a
        # fork, so carrying our commits would only confuse `git log`.
        FileUtils.rm_rf(File.join(target, ".git"))
        run_in(target, "git", ["init", "-q"])
        run_in(target, "git", ["add", "-A"])
        run_in(target, "git", ["commit", "-q", "-m", "Initial commit from the voipappz/app template"])

        write_env(target, mothership)

        puts VoIPAppz::Colors.green("Created #{target}")
        puts ""
        puts VoIPAppz::Colors.bold("Next:")
        puts "  cd #{arguments.name}"
        puts "  make dev                    # http://localhost:4200 (docker only, no local node needed)"
        puts "  voipappz app deploy -d <destination>"
      end

      private def clone(target : String) : Bool
        status = Process.run("git",
          ["clone", "--depth", "1", "--branch", flags.ref, TEMPLATE_REPO, target],
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        status.success? && Dir.exists?(target)
      end

      private def run_in(dir : String, cmd : String, args : Array(String))
        Process.run(cmd, args, chdir: dir,
          output: Process::Redirect::Close, error: Process::Redirect::Close)
      end

      # `.env` is the whole tenant configuration — the template's README is
      # explicit that "a tenant fork changes env, not code".
      private def write_env(target : String, mothership : String)
        example = File.join(target, ".env.example")
        env = File.join(target, ".env")
        return unless File.exists?(example)

        body = File.read(example)
        unless mothership.empty?
          body = body.gsub(/^MOTHERSHIP_URL=.*$/m, "MOTHERSHIP_URL=#{mothership}")
        end
        File.write(env, body)
        puts "  wrote .env#{mothership.empty? ? "" : " (MOTHERSHIP_URL=#{mothership})"}"
      end
    end

    class Deploy < Admiral::Command
      define_help description: "Generate the Kamal destination config and deploy the app"

      define_flag dest : String,
        description: "Destination name — reads config/deploy.<dest>.yml from the CLI project",
        short: d,
        default: ""

      define_flag path : String,
        description: "Path to the app repo",
        default: "."

      define_flag publish : Int32,
        description: "Host port to publish on when the node's proxy owns 80/443",
        default: VoIPAppz::AppDeploy::DEFAULT_PUBLISH_PORT

      define_flag no_kong : Bool,
        description: "Target a BARE host — let kamal-proxy front the app instead of publishing on loopback",
        default: false

      define_flag dry_run : Bool,
        description: "Print the generated config and the kamal command; change nothing",
        default: false

      def run
        if flags.dest.empty?
          STDERR.puts VoIPAppz::Colors.red("--dest is required (config/deploy.<dest>.yml in this project).")
          exit 1
        end

        app_dir = File.expand_path(flags.path)
        unless File.exists?(File.join(app_dir, "Dockerfile.production"))
          STDERR.puts VoIPAppz::Colors.red("#{app_dir} does not look like a voipappz app (no Dockerfile.production).")
          STDERR.puts VoIPAppz::Colors.dim("  Run this from the app directory, or pass --path.")
          exit 1
        end

        dest = begin
          VoIPAppz::DeployDestination.load(flags.dest, Dir.current)
        rescue ex
          STDERR.puts VoIPAppz::Colors.red(ex.message || "could not load destination")
          exit 1
        end

        kong = !flags.no_kong
        config = VoIPAppz::VaConfig.load(Dir.current)
        mothership = VoIPAppz::AppDeploy.mothership_url(config)
        yaml = VoIPAppz::AppDeploy.destination_yaml(
          dest, mothership: mothership, kong: kong, publish_port: flags.publish)

        out_path = File.join(app_dir, "config", "deploy.#{flags.dest}.yml")
        health = VoIPAppz::AppDeploy.healthcheck_url(kong, dest.domain)

        puts VoIPAppz::Colors.bold("Deploying the app to #{dest.host} (#{flags.dest})")
        puts "  proxy:      #{kong ? "kamal-proxy DISABLED — published 127.0.0.1:#{flags.publish} behind the node's Kong" : "kamal-proxy fronts :#{VoIPAppz::AppDeploy::APP_PORT}"}"
        puts "  env-file:   #{VoIPAppz::AppDeploy.env_file_path(dest.user)} #{VoIPAppz::Colors.dim("(place out-of-band on the host)")}"
        puts "  mothership: #{mothership.empty? ? VoIPAppz::Colors.dim("(not baked)") : mothership}"
        puts ""

        if flags.dry_run
          puts VoIPAppz::Colors.bold("#{out_path}:")
          puts yaml
          puts VoIPAppz::Colors.bold("Would run:")
          VoIPAppz::AppDeploy.stop_first?(kong) &&
            puts("  #{kamal_cmd(app_dir, ["app", "stop", "-d", flags.dest], health).join(" ")}")
          puts "  #{kamal_cmd(app_dir, ["deploy", "-d", flags.dest], health).join(" ")}"
          puts ""
          puts VoIPAppz::Colors.dim("Dry run — nothing written, nothing deployed.")
          return
        end

        Dir.mkdir_p(File.dirname(out_path))
        File.write(out_path, yaml)
        puts VoIPAppz::Colors.green("Wrote #{out_path}")

        # A fixed host port cannot be double-bound: kamal starts the new
        # container before removing the old one, so the second bind fails with
        # "Bind for 0.0.0.0:<port> failed: port is already allocated".
        if VoIPAppz::AppDeploy.stop_first?(kong)
          puts VoIPAppz::Colors.dim("  stopping the old container first (fixed host port)")
          Process.run("docker", kamal_cmd(app_dir, ["app", "stop", "-d", flags.dest], health)[1..],
            output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        end

        status = Process.run("docker", kamal_cmd(app_dir, ["deploy", "-d", flags.dest], health)[1..],
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        unless status.success?
          STDERR.puts VoIPAppz::Colors.red("kamal deploy failed")
          exit status.exit_code
        end
        puts VoIPAppz::Colors.green("Deployed.")
      end

      # Kamal runs from its own image — no ruby on the box, and everyone gets
      # the same version. Mirrors the app's Makefile exactly.
      private def kamal_cmd(app_dir : String, args : Array(String), health : String) : Array(String)
        # Kamal authenticates to the target over SSH using the caller's keys.
        # With HOME unset this would mount "//.ssh" and fail obscurely inside
        # the container, so say so here instead.
        home = ENV["HOME"]?
        if home.nil? || home.empty?
          STDERR.puts VoIPAppz::Colors.red("HOME is unset — cannot locate the SSH keys kamal needs.")
          exit 1
        end
        cmd = ["docker", "run", "--rm",
               "-v", "#{app_dir}:/workdir",
               "-v", "#{home}/.ssh:/root/.ssh:ro",
               "-v", "/var/run/docker.sock:/var/run/docker.sock",
               "-e", "KAMAL_REGISTRY_PASSWORD"]
        # Behind Kong the app is on loopback and unreachable from here, so the
        # post-deploy hook's probes would all return 000 and fail a deploy that
        # actually worked. Unset = the hook skips itself.
        cmd += ["-e", "KAMAL_HEALTHCHECK_URL=#{health}"] unless health.empty?
        cmd + ["ghcr.io/basecamp/kamal:latest"] + args
      end
    end
  end
end
