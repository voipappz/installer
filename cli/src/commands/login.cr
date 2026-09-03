require "admiral"
require "../helpers/colors"

module VoIPAppz::Commands
  # `voipappz login` — authenticate with the Docker registry that holds
  # the private nirlevi/* images (kamailio, freeswitch, api, crystal).
  # On a fresh machine `voipappz up` cannot pull them without this; the
  # login persists in ~/.docker/config.json so this is a one-time step.
  class Login < Admiral::Command
    define_help description: "Log in to the Docker registry hosting the private images"

    define_flag user : String,
      description: "Docker Hub username",
      default: "nirlevi",
      short: u
    define_flag token : String,
      description: "Docker Hub password / access token (otherwise reads $DOCKERHUB_TOKEN, then secrets/dockerhub_token.txt, else prompts on the TTY)",
      short: t
    define_flag registry : String,
      description: "Registry URL (default: docker.io)",
      default: ""

    def run
      project_dir = VoIPAppz::Docker.project_dir

      user = flags.user
      token = resolve_token(project_dir)
      registry = flags.registry

      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::KEY} Docker Registry Login")
      puts ""
      puts "  user:     #{VoIPAppz::Colors.cyan(user)}"
      puts "  registry: #{VoIPAppz::Colors.cyan(registry.empty? ? "docker.io" : registry)}"
      puts "  token:    #{token.empty? ? VoIPAppz::Colors.warning("(missing — will be prompted)") : VoIPAppz::Colors.dim(token[0, 4] + "*" * 8)}"
      puts ""

      argv = ["login", "--username", user]
      argv << registry unless registry.empty?

      if token.empty?
        # Interactive — let docker prompt directly on the TTY.
        status = Process.run("docker", argv,
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit)
      else
        argv << "--password-stdin"
        # Pipe token over stdin to avoid leaking via process listings.
        process = Process.new("docker", argv,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit)
        process.input.print(token)
        process.input.close
        status = process.wait
      end

      if status.success?
        puts ""
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} Logged in — docker pull on private images will now succeed")
      else
        STDERR.puts VoIPAppz::Colors.error("Docker login failed (exit #{status.exit_code})")
        exit 1
      end
    end

    # Resolve the token in priority order:
    #   1. --token CLI flag
    #   2. DOCKERHUB_TOKEN env
    #   3. secrets/dockerhub_token.txt
    #   4. empty (= interactive prompt)
    private def resolve_token(project_dir : String) : String
      cli = flags.token
      return cli if cli && !cli.empty?

      env_tok = ENV["DOCKERHUB_TOKEN"]?
      return env_tok if env_tok && !env_tok.empty?

      secrets_file = File.join(project_dir, "secrets", "dockerhub_token.txt")
      if File.exists?(secrets_file)
        v = File.read(secrets_file).strip
        return v unless v.empty?
      end

      ""
    end
  end
end
