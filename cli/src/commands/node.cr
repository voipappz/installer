require "admiral"
require "file_utils"
require "../helpers/colors"
require "../helpers/docker"
require "../helpers/node_registration"
require "../helpers/node_install"
require "../helpers/va_config"

module VoIPAppz::Commands
  class Node < Admiral::Command
    define_help description: "Install a VoIP node, and manage its registration"
    register_sub_command register, type: NodeRegister
    register_sub_command install, type: NodeInstall

    def run
      puts help
    end
  end

  # `voipappz node install` — a SEPARATE VoIP node against this mothership,
  # here or over ssh. Ported from scripts/install-node.sh so the interface is
  # the CLI, like every other verb.
  #
  # It launches the public node installer; it does not reimplement the install.
  # See helpers/node_install.cr for what that boundary is and why it holds.
  class NodeInstall < Admiral::Command
    define_help description: "Install a separate VoIP node against this mothership"

    define_flag host : String,
      description: "Install on another machine over ssh, as user@host (default: this machine)",
      default: ""
    define_flag dry_run : Bool,
      description: "Print what would run, with secret VALUES redacted; change nothing",
      default: false
    define_flag installer : String,
      description: "A local install.sh to run instead of the published one (default: ../installer)",
      default: ""
    # install.sh's own flag, passed through rather than reimplemented. For a
    # node whose mothership is not reachable yet, and for CI, which installs a
    # node against a stub that answers /health and nothing else. The node runs;
    # the platform does not know it exists until `voipappz node register`.
    define_flag no_register : Bool,
      description: "Install and start the node, but do not register it with the mothership",
      default: false

    def run
      values = VoIPAppz::NodeInstall.mothership_env
      unless values["VA_API_URL"]?
        STDERR.puts VoIPAppz::Colors.red("VA_API_URL not set and not in .env")
        exit 1
      end
      # --no-register never reaches the API, so it needs no credential for it.
      unless VoIPAppz::NodeInstall.credentialed? || flags.dry_run || flags.no_register
        STDERR.puts VoIPAppz::Colors.red("set VA_API_AUTHORIZATION='Basic …' or VA_API_EMAIL/VA_API_PASSWORD")
        STDERR.puts VoIPAppz::Colors.dim("  Credentials come from the environment only — never from .env, which")
        STDERR.puts VoIPAppz::Colors.dim("  the CLI deliberately refuses to read VA_API_AUTHORIZATION out of.")
        exit 1
      end

      remote = flags.host
      if !remote.empty? && VoIPAppz::NodeInstall.loopback?(values)
        STDERR.puts VoIPAppz::Colors.red(
          "VA_API_URL/VA_NATS_URL point at 127.0.0.1 — a remote node cannot reach them")
        STDERR.puts VoIPAppz::Colors.dim("  Set the mothership's real address before installing on #{remote}.")
        exit 1
      end

      # THE INSTALLER DELETES docker-compose.yaml FROM ITS INSTALL DIR, and it
      # cannot tell a stale compose-era file from a live mothership. Checked
      # only for a LOCAL install — a remote target is someone else's machine.
      if remote.empty? && !flags.dry_run
        dir = VoIPAppz::NodeInstall.install_dir
        if VoIPAppz::NodeInstall.mothership_dir?(dir)
          STDERR.puts VoIPAppz::Colors.red("#{dir} holds a docker-compose.yaml — a mothership lives there")
          STDERR.puts VoIPAppz::Colors.dim("  The installer DELETES that file (install.sh commit_install_dir): a stale")
          STDERR.puts VoIPAppz::Colors.dim("  compose file would start a second node beside the one it runs. It cannot")
          STDERR.puts VoIPAppz::Colors.dim("  tell a stale one from a live stack, so `up`/`down`/`status` would lose")
          STDERR.puts VoIPAppz::Colors.dim("  the file they read.")
          STDERR.puts VoIPAppz::Colors.dim("  Install the node elsewhere:  INSTALL_DIR=/opt/va-node make node-install")
          exit 1
        end
      end

      answers = VoIPAppz::NodeInstall.answer_file(values)
      source = begin
        VoIPAppz::NodeInstall.installer_source(flags.installer)
      rescue ex : VoIPAppz::NodeInstall::Failed
        STDERR.puts VoIPAppz::Colors.red(ex.message.to_s)
        exit 1
      end

      args = [] of String
      args << "--no-register" if flags.no_register

      if flags.dry_run
        target = remote.empty? ? "this machine" : remote
        puts VoIPAppz::Colors.bold("would install a node on #{target}, against #{values["VA_API_URL"]}")
        puts "  installer: #{VoIPAppz::NodeInstall.describe(source)}"
        puts "  command:   #{VoIPAppz::NodeInstall.command(source, args)}"
        puts "  answers:"
        answers.each_line { |line| puts "    #{redact(line)}" }
        return
      end

      remote.empty? ? install_here(values, answers, source, args) : install_remote(remote, values, answers, source, args)
    end

    # A secret is worth printing the NAME of and never the value: --dry-run is
    # the flag people paste into an issue.
    #
    # NAMING THE SECRET KEYS IS NOT ENOUGH. VA_NATS_URL is
    # `nats://user:password@host` — a credential inside a value whose key says
    # nothing about it, and the first draft of this printed it in full. Any
    # userinfo in any URL goes too.
    private def redact(line : String) : String
      key, _, value = line.partition('=')
      return "#{key}=<redacted>" if key.ends_with?("AUTHORIZATION") ||
                                    key.ends_with?("PASSWORD") ||
                                    key.ends_with?("TOKEN") ||
                                    key.ends_with?("SECRET")
      "#{key}=#{value.rstrip.gsub(/(\w+:\/\/[^:@\s]+):[^@\s]+@/, "\\1:<redacted>@")}"
    end

    private def install_here(values : Hash(String, String), answers : String,
                             source : {Symbol, String}, args : Array(String))
      puts VoIPAppz::Colors.bold("── installing a node on THIS machine, against #{values["VA_API_URL"]}")
      puts VoIPAppz::Colors.dim("   installer: #{VoIPAppz::NodeInstall.describe(source)}")
      dir = File.tempname("voipappz-node-install")
      Dir.mkdir_p(dir)
      File.chmod(dir, 0o700)
      begin
        env = File.join(dir, ".env")
        File.write(env, answers)
        File.chmod(env, 0o600)
        # The installer reads ./.env from the directory it runs in.
        command = VoIPAppz::NodeInstall.command(source, args)
        status = Process.run("sh", ["-c", command],
          chdir: dir,
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        exit status.exit_code unless status.success?
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    # The answer file travels on the SSH CHANNEL, on stdin — not argv, not scp.
    # SSH.run cannot pipe stdin, so this drives ssh directly rather than
    # weakening that property to reuse the helper.
    private def install_remote(target : String, values : Hash(String, String), answers : String,
                               source : {Symbol, String}, args : Array(String))
      puts VoIPAppz::Colors.bold("── installing a node on #{target}, against #{values["VA_API_URL"]}")
      puts VoIPAppz::Colors.dim("   installer: #{VoIPAppz::NodeInstall.describe(source)}")
      script = VoIPAppz::NodeInstall.remote_script(answers, source, args)

      process = Process.new("ssh", [target, "sh -s"],
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)
      process.input.print script
      process.input.close
      status = process.wait
      exit status.exit_code unless status.success?
    end
  end

  class NodeRegister < Admiral::Command
    define_help description: "Register this va.yaml node in the mothership"

    def run
      result = VoIPAppz::NodeRegistration.register(
        VoIPAppz::VaConfig.yaml_path(VoIPAppz::Docker.project_dir),
        ENV["VA_API_AUTHORIZATION"]? || ""
      )

      action = case result.operation
               when .created?  then "registered"
               when .updated?  then "registration updated"
               when .existing? then "already registered — no changes"
               else                 "registered"
               end
      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} node #{result.node_uuid} #{action}")
    rescue ex : VoIPAppz::NodeRegistration::Error
      STDERR.puts VoIPAppz::Colors.error("Node registration failed: #{ex.message}")
      exit 1
    end
  end
end
