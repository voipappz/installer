require "./colors"
require "./env_file"
require "./project"

module VoIPAppz
  # Everything `voipappz portal` knows that is not an Admiral flag.
  #
  # The portal is github.com/voipappz/app — its OWN repo, cloned beside this one.
  # It was a git subtree here until 2026-08-31. It is NOT the mothership stack,
  # which is why none of this goes through VoIPAppz::Docker: that helper resolves
  # Project.compose_file and would aim every portal command at the mothership's
  # containers.
  #
  # THE SPLIT THAT MATTERS: the app repo carries the SOURCE (package.json,
  # agents_demo/, Dockerfile.production, docker-compose.yml). This repo carries
  # the DEPLOY
  # POLICY, in config/portal/ — deploy.yml, the destination overrides,
  # portal-destinations.tsv and .kamal/. Choosing where the portal lands needs
  # the view of every destination at once, and only mothership has it.
  #
  # So every command here takes TWO directories: `dir` (the app checkout) and
  # `conf_dir` (config/portal, always in this repo). Do not collapse them.
  module Portal
    extend self

    DEFAULT_MOTHERSHIP = "https://cloud.voipappz.io"
    # 4001 is THE ORIGIN and does not move: the SPA, the Chrome extension and
    # Vite's proxy all point at it. It was called DENO_API when a Deno BFF held
    # that port; the Elixir portal holds it now and the name was the last thing
    # still saying otherwise.
    PORTAL             = "http://localhost:4001"
    WEB_APP            = "http://localhost:4200"

    class NotFound < Exception; end

    # --path → $VA_PORTAL_DIR → the sibling clone beside this repo.
    #
    # A SIBLING, not a path inside this repo. There is no apps/ here any more:
    # vendoring the app back in is what the 2026-08-31 split undid, and a
    # symlink standing in for it only moved the problem (dangling on every
    # fresh clone, a text file on Windows, absent in CI).
    def sibling : String
      File.join(File.dirname(VoIPAppz::Project.root), "app")
    end

    def dir(override : String = "") : String
      candidate =
        if !override.empty?
          File.expand_path(override)
        elsif (env = ENV["VA_PORTAL_DIR"]?) && !env.empty?
          File.expand_path(env)
        else
          sibling
        end

      unless portal?(candidate)
        raise NotFound.new(
          "#{candidate} does not look like the portal (no package.json + agents_demo/mix.exs).\n" \
          "  The portal is github.com/voipappz/app, cloned BESIDE this repo:\n" \
          "    git clone https://github.com/voipappz/app #{sibling}\n" \
          "  Or pass --path, or set VA_PORTAL_DIR.")
      end
      candidate
    end

    # ------------------------------------------------------------ deploy config
    #
    # ALWAYS this repo, never the app checkout. config/portal/ is the deploy
    # policy — see the module comment. Resolved from Project.root so it is right
    # whether the caller is in this repo, the app repo, or neither.
    def conf_dir : String
      File.join(VoIPAppz::Project.root, "config", "portal")
    end

    # What every command calls: resolve, or explain and stop. The commands take
    # a directory and do their work; none of them should each carry a copy of
    # this rescue.
    def dir!(override : String = "") : String
      dir(override)
    rescue ex : NotFound
      STDERR.puts Colors.red(ex.message.to_s)
      exit 1
    end

    # Dockerfile.production is NOT the marker: the voipappz/app template ships
    # one too, so it cannot tell the portal from a customer app — and pointing
    # `portal deploy` at a customer app would deploy the wrong thing to the
    # right host.
    #
    # config/deploy.yml and .kamal/ USED to be two of the three markers. They
    # are not in the app repo any more — they live in config/portal/ here — so
    # checking them would reject the real portal.
    #
    # THE MARKER MOVED WITH THE SERVER. It was api/server.ts, the Deno BFF that
    # served the bundle same-origin and forwarded /api, /auth and /tasks. That
    # BFF is gone — the Elixir portal does that job now — so api/ no longer
    # exists and this check rejected the real portal with "no package.json +
    # api/server.ts", i.e. it told you to re-clone the repo you were standing
    # in. agents_demo/mix.exs is the replacement and is the better marker
    # anyway: no customer app template carries a Phoenix app.
    def portal?(dir : String) : Bool
      File.exists?(File.join(dir, "package.json")) &&
        File.exists?(File.join(dir, "agents_demo", "mix.exs"))
    end

    def env(dir : String) : Hash(String, String)
      # first_wins: the Makefile read these with `sed … | head -1`.
      EnvFile.load(File.join(dir, ".env"), first_wins: true)
    end

    # The mothership base, resolved exactly as vite.config.js does, so a
    # preflight always probes the host Vite actually proxies to.
    # VITE_API_TARGET wins over MOTHERSHIP_URL — by PRECEDENCE, not by whichever
    # appears first in the file.
    def mothership(dir : String) : String
      EnvFile.first_set(env(dir), ["VITE_API_TARGET", "MOTHERSHIP_URL"]) || DEFAULT_MOTHERSHIP
    end

    def prod_url(dir : String) : String
      env(dir)["PROD_URL"]? || ""
    end

    # ---------------------------------------------------------------- destinations

    record Destination,
      name : String,
      stop_first : Bool,
      healthcheck : String

    DEFAULT_KEY = "(default)"

    def destinations_path : String
      File.join(conf_dir, "portal-destinations.tsv")
    end

    def destinations : Hash(String, Destination)
      buf = {} of String => Destination
      path = destinations_path
      return buf unless File.exists?(path)

      File.each_line(path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        fields = line.split('\t').map(&.strip).reject(&.empty?)
        next if fields.size < 3
        name, stop, health = fields[0], fields[1], fields[2]
        buf[name] = Destination.new(name, stop == "yes", health == "-" ? "" : health)
      end
      buf
    end

    # An UNLISTED destination is an error, not a default. A fixed-port host that
    # silently inherits `stop_first: no` fails its next deploy with the exit-125
    # port collision, and the message blames docker rather than this table.
    def destination(dest : String) : Destination
      key = dest.empty? ? DEFAULT_KEY : dest
      table = destinations
      if found = table[key]?
        return found
      end
      known = table.keys.sort.join(", ")
      raise NotFound.new(
        "destination '#{key}' is not in #{destinations_path}.\n" \
        "  known: #{known}\n" \
        "  Add a row before deploying — the file says what stop_first and\n" \
        "  healthcheck_url mean and why each existing row is set the way it is.")
    end

    # $PROD_URL in the table resolves from the portal's .env.
    def healthcheck_url(dir : String, dest : Destination) : String
      return prod_url(dir) if dest.healthcheck == "$PROD_URL"
      dest.healthcheck
    end

    # ---------------------------------------------------------------- secrets
    #
    # THE TRAP THE MAKEFILE WALKED INTO. It checked `.kamal/secrets` for every
    # destination, but `kamal deploy -d <dest>` reads .kamal/secrets-common and
    # .kamal/secrets.<dest> ONLY — never .kamal/secrets. So `make deploy
    # DEST=mtn` passed its own precheck and then died inside the container with
    #   Secret 'KAMAL_REGISTRY_PASSWORD' not found, no secret files
    #   (.kamal/secrets-common, .kamal/secrets.<dest>) provided
    # Check what kamal will actually read, and fail here with the fix.

    def secret_files(dest : String) : Array(String)
      k = File.join(conf_dir, ".kamal")
      return [File.join(k, "secrets")] if dest.empty?
      [File.join(k, "secrets-common"), File.join(k, "secrets.#{dest}")]
    end

    def check_secrets!(dest : String) : Nil
      required = secret_files(dest)
      return if required.any? { |f| File.exists?(f) }

      rel = required.map { |f| f.sub(File.dirname(conf_dir) + "/", "") }
      STDERR.puts Colors.red("missing #{rel.join(" or ")}")
      if dest.empty?
        STDERR.puts Colors.dim("  cp config/portal/.kamal/secrets.example config/portal/.kamal/secrets   # then fill it in")
      else
        STDERR.puts Colors.dim("  `kamal deploy -d #{dest}` reads secrets-common and secrets.#{dest} only —")
        STDERR.puts Colors.dim("  NOT .kamal/secrets, whatever else is present.")
        STDERR.puts Colors.dim("  cp config/portal/.kamal/secrets.example config/portal/.kamal/secrets-common   # then fill it in")
      end
      exit 1
    end

    # What the CLI itself reads to populate KAMAL_REGISTRY_PASSWORD for the
    # child. Layered lowest-first: .kamal/secrets keeps every setup that works
    # today working, and the destination files override it the way kamal's own
    # rule does.
    def secrets(dest : String) : Hash(String, String)
      k = File.join(conf_dir, ".kamal")
      paths = [File.join(k, "secrets")]
      paths += [File.join(k, "secrets-common"), File.join(k, "secrets.#{dest}")] unless dest.empty?
      EnvFile.layer(paths)
    end

    # ---------------------------------------------------------------- compose
    #
    # The portal's own compose project. No -f: its docker-compose.yml is the one
    # beside it, and chdir is what selects the project.
    def compose(dir : String, args : Array(String), capture : Bool = false) : {Int32, String}
      buf = IO::Memory.new
      process = Process.new("docker", ["compose"] + args,
        chdir: dir,
        input: Process::Redirect::Inherit,
        output: capture ? buf : Process::Redirect::Inherit,
        error: capture ? buf : Process::Redirect::Inherit)
      {process.wait.exit_code, buf.to_s}
    end

    def compose!(dir : String, args : Array(String)) : Nil
      code, _ = compose(dir, args)
      return if code == 0
      STDERR.puts Colors.red("docker compose #{args.join(" ")} failed (exit #{code})")
      exit code
    end

    # One-off npm in the react-app service: repo mount plus the cached
    # node_modules volume, so no host node is needed for anything.
    def npm!(dir : String, script : String) : Nil
      compose!(dir, ["run", "--rm", "--no-deps", "react-app", "bash", "-c",
                     "npm install --loglevel=error --no-audit --no-fund && npm run #{script}"])
    end

    # ---------------------------------------------------------------- probes

    # `id -u`/`id -g`, as the Makefile did. Crystal exposes neither getuid nor
    # getgid through Process, and the values are only ever needed as the string
    # docker's --user wants.
    def user_group : String
      buf = IO::Memory.new
      Process.run("sh", ["-c", "printf '%s:%s' \"$(id -u)\" \"$(id -g)\""],
        output: buf, error: Process::Redirect::Close)
      value = buf.to_s.strip
      value.empty? ? "0:0" : value
    end

    # Status code for a GET, or "000" when nothing answered.
    def http_code(url : String, timeout : Int32 = 5) : String
      buf = IO::Memory.new
      Process.run("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}",
                           "--max-time", timeout.to_s, url],
        output: buf, error: Process::Redirect::Close)
      code = buf.to_s.strip
      code.empty? ? "000" : code
    end

    def get(url : String, timeout : Int32 = 5) : String?
      buf = IO::Memory.new
      status = Process.run("curl", ["-sk", "--max-time", timeout.to_s, url],
        output: buf, error: Process::Redirect::Close)
      status.success? ? buf.to_s : nil
    end
  end
end
