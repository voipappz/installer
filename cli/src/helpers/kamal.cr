require "./colors"

module VoIPAppz
  # Running kamal, always from its official image — never a native/rvm install.
  # Any box with docker can deploy, and everyone runs the same kamal version.
  #
  # ONE runner for every caller. `app deploy` grew its own and drifted: no TTY,
  # no working directory, no git safe.directory, and `kamal:latest` where the
  # portal pins a version. Each of those is a production failure someone already
  # hit, recorded below, and none of them should have to be hit twice.
  module Kamal
    extend self

    # PINNED. `latest` makes a deploy non-reproducible in the same way an
    # unpinned image tag does — and kamal's config schema moves between minors,
    # so the version that renders config/deploy.yml is part of the contract.
    IMAGE = "ghcr.io/basecamp/kamal:v2.12.0"

    # Build the argv for `kamal <args>` against a project at `dir`.
    #
    # mount_root: what gets bind-mounted at /workdir. It is the GIT ROOT, not
    # the project directory, because kamal derives the image version from git
    # (`git rev-parse --short HEAD` in an ERB tag in config/deploy.yml) and
    # mounting a project alone leaves kamal in a directory that is not a
    # repository. For the portal the two are now the same — its own repo — but
    # they were not while it was a subtree here, and a customer app under a
    # monorepo still needs the distinction.
    # conf_dir: the deploy config to layer OVER the checkout — config/portal in
    # the mothership repo. The portal's source and its deploy policy live in two
    # different repos since 2026-08-31, so kamal has to be handed both: the app
    # checkout is the build context and the git root, and config/portal supplies
    # config/deploy*.yml and .kamal/hooks. Read-only, and mounted at the paths
    # kamal looks for them, so nothing in the app repo has to know about it.
    def command(dir : String, args : Array(String),
                healthcheck : String = "",
                mount_root : String? = nil,
                conf_dir : String? = nil) : Array(String)
      root = mount_root || git_root(dir) || dir
      # File.join("/workdir", "") is "/workdir/" — a trailing slash docker
      # accepts but that reads as a typo in every printed command.
      rel = relative(root, dir)
      workdir = rel.empty? ? "/workdir" : File.join("/workdir", rel)

      cmd = ["docker", "run", "--rm"]

      # A TTY WHEN WE HAVE ONE. Without it any prompt inside the container — an
      # ssh password, a host-key confirmation — dies as
      #   ERROR (Errno::ENOTTY): Exception while executing on host …: Not a tty
      # with no way to answer. Conditional, because `docker run -it` fails
      # outright where stdin is not a terminal, which is every CI run.
      cmd << "-it" if STDIN.tty?

      cmd += ["-v", "#{root}:/workdir", "-w", workdir]

      if conf = conf_dir
        cmd += ["-v", "#{conf}:#{File.join(workdir, "config")}:ro"]
        cmd += ["-v", "#{File.join(conf, ".kamal")}:#{File.join(workdir, ".kamal")}:ro"]
      end

      # kamal authenticates to the target over SSH with the caller's keys.
      if home = home_dir
        cmd += ["-v", "#{home}/.ssh:/root/.ssh:ro"]
      end
      cmd += ["-v", "/var/run/docker.sock:/var/run/docker.sock"]

      # BY NAME, never `-e KEY=value`: the registry PAT would otherwise sit in
      # the process table for any `ps aux` to read.
      cmd += ["-e", "KAMAL_REGISTRY_PASSWORD"]

      # Unset means the post-deploy hook SKIPS its probes, which is a real
      # setting and not an oversight — see PortalDestinations.
      cmd += ["-e", "KAMAL_HEALTHCHECK_URL"] unless healthcheck.empty?

      # The container's root user is not the host owner of the checkout, so git
      # refuses to read it ("detected dubious ownership") and kamal's version
      # derivation fails inside the ERB.
      cmd += ["-e", "GIT_CONFIG_COUNT=1",
              "-e", "GIT_CONFIG_KEY_0=safe.directory",
              "-e", "GIT_CONFIG_VALUE_0=*"]

      cmd + [IMAGE] + args
    end

    # HOME must exist before we mount ~/.ssh: unset, docker mounts "//.ssh" and
    # fails obscurely inside the container instead of here.
    def home_dir : String?
      home = ENV["HOME"]?
      return nil if home.nil? || home.empty?
      home
    end

    def git_root(dir : String) : String?
      buf = IO::Memory.new
      status = Process.run("git", ["rev-parse", "--show-toplevel"],
        chdir: dir, output: buf, error: Process::Redirect::Close)
      return nil unless status.success?
      root = buf.to_s.strip
      root.empty? ? nil : root
    end

    private def relative(root : String, dir : String) : String
      r = File.expand_path(root)
      d = File.expand_path(dir)
      return "" if r == d
      d.starts_with?(r + "/") ? d[(r.size + 1)..] : ""
    end
  end
end
