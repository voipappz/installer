require "admiral"
require "json"
require "../helpers/colors"
require "../helpers/services"
require "../helpers/table"
require "../helpers/ssh"
require "../helpers/secrets"
require "../helpers/deploy_config"
require "../helpers/deploy_destination"
require "../helpers/deploy_manifest"
require "../helpers/bootstrap"
require "../helpers/runner"

module VoIPAppz::Commands
  class Deploy < Admiral::Command
    define_help description: "Deploy this node (or a remote one with -d/--host)"

    define_flag host : String,
      description: "Target server IP/hostname",
      short: h
    define_flag user : String,
      description: "SSH user",
      default: "root",
      short: u
    define_flag password : String,
      description: "SSH password (alternative to key)",
      short: p
    define_flag key : String,
      description: "SSH private key path",
      default: "~/.ssh/id_rsa",
      short: k
    define_flag ssh_port : Int32,
      description: "SSH port",
      default: 22
    define_flag config : String,
      description: "Path to va.yaml config file",
      short: c,
      default: ""
    define_flag dry_run : Bool,
      description: "Simulate deployment without changes",
      default: false
    define_flag validate_only : Bool,
      description: "Validate deployment configuration only",
      default: false
    define_flag skip_provision : Bool,
      description: "Skip host provisioning (apt/usermod/ufw) — for a pre-bootstrapped, non-root, docker-ready host (Kamal-style)",
      default: false
    define_flag dest : String,
      description: "Deploy destination: loads config/deploy.<dest>.yml (Kamal-style per-server file)",
      short: d,
      default: ""
    define_flag check : Bool,
      description: "Connectivity preflight: verify SSH + docker readiness, then exit (no changes)",
      default: false
    define_flag profile : String,
      description: "Profiles to bring up, comma-separated (default: app locally, voip remotely)",
      short: P,
      default: ""

    # The repo-file => host-path manifest lives in a pure helper so a spec can
    # cross-check it against the docker-compose bind mounts (see
    # cli/spec/deploy_manifest_spec.cr). Adding `kamailio.lua` here is what
    # fixed the empty-dir clobber on pbx20.
    # Read from config/deploy-manifest.tsv (data, not a constant) — see the note
    # in deploy_manifest.cr: `deploy` is becoming shell and reads the same file.
    def self.deploy_files : Hash(String, String)
      VoIPAppz::DeployManifest.files
    end

    FIREWALL_PORTS = [
      "22/tcp",
      "80/tcp",
      "443/tcp",
      "5000/tcp",
      "5060/udp",
      "5060/tcp",
      "8443/tcp",
      "9000/tcp",
      "16384:32768/udp",
    ]


    def run
      # No --host and no --dest means THIS machine. Decided first, because every
      # branch below differs: `--check` is an ssh preflight, and the remote
      # `--dry-run` renders a plan for a host that, locally, does not exist.
      remote_target = !flags.host.to_s.empty? || !flags.dest.empty?

      unless remote_target
        if flags.validate_only
          validate_config
          return
        end
        deploy_local!   # handles its own --dry-run and --check
        return
      end

      if flags.check
        preflight
        return
      end

      if flags.validate_only
        validate_config
        return
      end

      if flags.dry_run
        dry_run
        return
      end

      deploy!
    end

    # Deploy THIS machine. No ssh, no upload, no provisioning.
    #
    # The app plane runs on the node the CLI is already sitting on: the repo is
    # here, .env is here, docker is here. Pushing the same commands through ssh
    # to localhost adds a key, a daemon and a whole class of failure that has
    # nothing to do with the deploy. `voipappz deploy -d <dest>` is still there
    # for the case that genuinely needs a network hop — shipping the `voip`
    # profile to a separate switch box.
    #
    # Deliberately NOT here, because none of it means anything locally:
    # apt/docker install (docker is running or the command cannot work at all),
    # ufw, uploading files onto themselves, and patching .env with IPs detected
    # over ssh — `voipappz setup` already resolved those from this machine.
    private def deploy_local!
      runner = VoIPAppz::LocalRunner.new(VoIPAppz::SecretsHelper.project_dir)
      profs = profiles(true)

      puts VoIPAppz::Colors.bold("Deploying VoIPAppz locally")
      puts "  Project:  #{runner.workdir}"
      puts "  Profiles: #{profs.join(", ")}"
      puts ""

      unless File.exists?(File.join(runner.workdir, ".env"))
        STDERR.puts VoIPAppz::Colors.red("No .env in #{runner.workdir} — run `voipappz setup` first.")
        exit 1
      end

      # One probe, two uses: --check reports and exits, a real deploy fails fast.
      # It was written twice, with two different error messages for one fault.
      code, _ = runner.run("docker info >/dev/null 2>&1")
      unless code == 0
        STDERR.puts VoIPAppz::Colors.red("Cannot talk to docker on this machine.")
        STDERR.puts VoIPAppz::Colors.dim("  Is the daemon running, and is this user in the docker group?")
        exit 1
      end
      if flags.check
        puts VoIPAppz::Colors.green("docker is reachable — ready to deploy locally")
        return
      end

      if flags.dry_run
        puts VoIPAppz::Colors.bold("Would run:")
        puts "  docker compose #{compose_flags(profs)} pull"
        puts "  docker compose #{compose_flags(profs)} up -d"
        puts ""
        puts VoIPAppz::Colors.dim("Dry run — nothing pulled, nothing started.")
        return
      end

      step("1/3 Pulling Images") do
        runner.in_project("docker compose #{compose_flags(profs)} pull")
      end

      step("2/3 Starting Services") do
        code, output = runner.in_project("docker compose #{compose_flags(profs)} up -d")
        unless code == 0
          STDERR.puts VoIPAppz::Colors.red("docker compose up failed (exit #{code})")
          STDERR.puts VoIPAppz::Colors.dim(output.lines.last(15).join("\n"))
          exit code
        end
      end

      step("3/3 Waiting for Services") do
        wait_for_services(runner, profs)
      end

      verify!(runner, profs)

      puts ""
      puts VoIPAppz::Colors.green("Deployed locally (#{profs.join(", ")}).")
      puts VoIPAppz::Colors.dim("  voipappz status      # what is running")
      puts VoIPAppz::Colors.dim("  voipappz sbc ingress sync  /  voipappz sbc egress sync   # seed the SIP plane")
    end

    # Connectivity preflight — the FIRST thing to run for a new server. Verifies
    # we can actually reach + log into the host (key/user/port) and reports docker
    # readiness, before any change is attempted. Everything via the CLI:
    #   voipappz deploy -d <dest> --check
    private def preflight
      config = load_config
      host, user, password, key_path, port = resolve_params(config)

      puts VoIPAppz::Colors.bold("Connectivity preflight → #{user}@#{host}:#{port}")
      puts VoIPAppz::Colors.dim("  key: #{key_path}")
      puts ""

      rows = [] of Array(String)
      all_ok = true
      add = ->(name : String, ok : Bool, detail : String) do
        all_ok = false unless ok
        rows << [name, ok ? VoIPAppz::Colors.ok : VoIPAppz::Colors.fail, detail]
      end

      code, who = VoIPAppz::SSH.run(host, user, "whoami", password, key_path, port, true)
      ssh_ok = code == 0 && !who.strip.empty?
      add.call("SSH connect", ssh_ok, ssh_ok ? "logged in as #{who.strip}" : "cannot connect — check key/user/port/host")

      if ssh_ok
        _, dver = VoIPAppz::SSH.run(host, user, "docker --version 2>/dev/null || echo MISSING", password, key_path, port, true)
        has_docker = !dver.includes?("MISSING")
        add.call("docker installed", has_docker, has_docker ? dver.strip : "missing — deploy will provision (omit --skip-provision)")

        _, groups = VoIPAppz::SSH.run(host, user, "id -nG 2>/dev/null", password, key_path, port, true)
        in_docker = groups.split.includes?("docker")
        add.call("user in docker group", in_docker, in_docker ? "yes" : "no — deploy uses sudo / usermod")

        _, sudo = VoIPAppz::SSH.run(host, user, "sudo -n true 2>/dev/null && echo NOPASS || echo PASSWORD", password, key_path, port, true)
        nopass = sudo.includes?("NOPASS")
        add.call("passwordless sudo", nopass, nopass ? "yes" : "no — pass --password for provisioning steps")
      end

      columns = [
        VoIPAppz::Table::Column.new("Check", 22),
        VoIPAppz::Table::Column.new("", 6),
        VoIPAppz::Table::Column.new("Detail", 46),
      ]
      puts VoIPAppz::Table.render(columns, rows, title: "Preflight")
      puts ""
      if ssh_ok
        puts VoIPAppz::Colors.green("Reachable. Next: voipappz deploy -d #{flags.dest.empty? ? "<dest>" : flags.dest}")
      else
        puts VoIPAppz::Colors.red("Not reachable — fix connectivity before deploying.")
        exit 1
      end
    end

    # Load deploy config from va.yaml, with CLI flags as overrides
    private def load_config : VoIPAppz::DeployConfig?
      config_path = flags.config
      if config_path.empty?
        # Try default location
        project_dir = VoIPAppz::SecretsHelper.project_dir
        default_path = File.join(project_dir, "config", "va.yaml")
        config_path = default_path if File.exists?(default_path)
      end

      return nil if config_path.empty? || !File.exists?(config_path)

      begin
        VoIPAppz::DeployConfig.load(config_path)
      rescue ex
        puts VoIPAppz::Colors.yellow("Warning: could not parse #{config_path}: #{ex.message}")
        nil
      end
    end

    # Load the Kamal-style per-server destination file (config/deploy.<dest>.yml)
    # when -d/--dest is given. Memoized so the file is read once.
    @destination : VoIPAppz::DeployDestination? = nil
    @destination_loaded = false

    private def destination : VoIPAppz::DeployDestination?
      return @destination if @destination_loaded
      @destination_loaded = true
      return @destination = nil if flags.dest.empty?
      @destination = VoIPAppz::DeployDestination.load(flags.dest, VoIPAppz::SecretsHelper.project_dir)
    end

    # Provisioning is skipped via the CLI flag OR the destination file.
    private def skip_provision? : Bool
      flags.skip_provision || (destination.try(&.skip_provision) || false)
    end

    # Resolve host: CLI flag > destination file > va.yaml deploy section.
    private def resolve_host(config : VoIPAppz::DeployConfig?) : String
      flag_host = flags.host
      return flag_host if flag_host && !flag_host.empty?

      if dest = destination
        return dest.host unless dest.host.empty?
      end

      if config && (dc = config.deploy) && !dc.host.empty?
        return dc.host
      end

      STDERR.puts VoIPAppz::Colors.red("Error: --host is required (or -d <dest>, or deploy.host in va.yaml)")
      STDERR.puts "Usage: voipappz deploy --host <ip> | -d <dest>   (dest = config/deploy.<dest>.yml)"
      exit 1
    end

    # Resolve connection params. Precedence: CLI flag > destination file > va.yaml.
    private def resolve_params(config : VoIPAppz::DeployConfig?)
      home = ENV["HOME"]? || ""
      host = resolve_host(config)
      user = flags.user
      password = flags.password
      key_path = flags.key.gsub("~", home)
      port = flags.ssh_port

      if dest = destination
        # Kamal-style per-server file is the source; explicit CLI flags still win.
        user = dest.user if flags.user == "root"
        port = dest.ssh_port if flags.ssh_port == 22
        key_path = dest.key_path if flags.key == "~/.ssh/id_rsa"
      elsif config && (dc = config.deploy)
        user = dc.user unless flags.user != "root"  # only override if not explicitly set
        port = dc.ssh_port if flags.ssh_port == 22 && dc.ssh_port != 22
        if password.nil? && !dc.password.empty?
          password = dc.password
        end
        if flags.key == "~/.ssh/id_rsa" && !dc.key.empty?
          key_path = dc.key.gsub("~", home)
        end
      end

      {host, user, password, key_path, port}
    end

    private def validate_config
      puts VoIPAppz::Colors.bold("Validating deployment configuration...")
      errors = [] of String

      project_dir = VoIPAppz::SecretsHelper.project_dir
      compose_file = File.join(project_dir, "docker-compose.yaml")

      unless File.exists?(compose_file)
        errors << "docker-compose.yaml not found"
      else
        stdout = IO::Memory.new
        process = Process.new("docker", ["compose", "-f", compose_file, "config", "-q"],
          output: stdout, error: stdout)
        unless process.wait.success?
          errors << "docker-compose.yaml validation failed"
        end
      end

      # Validate va.yaml config
      config = load_config
      if config
        puts VoIPAppz::Colors.green("  va.yaml loaded")
        if config.nodes.empty?
          errors << "No nodes defined in va.yaml"
        end
      else
        puts VoIPAppz::Colors.yellow("  va.yaml not found (will use CLI flags)")
      end

      # Validate secrets
      valid, missing = VoIPAppz::SecretsHelper.validate_env
      unless valid
        missing.each { |s| errors << "Missing secret: #{s}" }
      end

      if errors.empty?
        puts VoIPAppz::Colors.green("Configuration validation passed")
      else
        errors.each { |e| puts VoIPAppz::Colors.red("  #{e}") }
        exit 1
      end
    end

    private def dry_run
      config = load_config
      host, user, password, key_path, port = resolve_params(config)

      puts VoIPAppz::Colors.bold("Deployment dry-run")
      puts ""

      columns = [
        VoIPAppz::Table::Column.new("Setting", 16),
        VoIPAppz::Table::Column.new("Value", 40),
      ]

      rows = [
        ["Host", host],
        ["User", user],
        ["Port", port.to_s],
        ["Auth", password ? "password" : "key (#{key_path})"],
        ["Config", flags.config.empty? ? "default" : flags.config],
      ]

      if config
        domain_name = config.domain.try(&.name) || ""
        rows << ["Domain", domain_name.empty? ? "(not set)" : domain_name]
        rows << ["SSL", (config.ssl.try(&.enabled) || false) ? (config.ssl.try(&.provider) || "acme.sh") : "disabled"]
        rows << ["DNS", config.domain.try(&.dns) || "manual"]
      end

      puts VoIPAppz::Table.render(columns, rows, title: "Deploy Target")

      puts ""
      puts VoIPAppz::Colors.bold("Steps that would execute:")
      puts "  1. Install packages (docker, docker-compose, curl, git, openssl)"
      puts "  2. Setup Docker (enable, start, add user to docker group)"
      puts "  3. Create directories (/opt/va/secrets, /opt/va/certs, /opt/va/config)"
      puts "  4. Upload files (compose, .env, kong, kamailio, va.yaml)"
      puts "  5. Configure firewall (#{FIREWALL_PORTS.size} port rules)"
      puts "  6. Generate secrets (postgres, s3, freeswitch passwords)"
      puts "  7. Detect public IP and update configuration"
      puts "  8. Start services (pull images, docker compose up)"
      puts "  9. Setup SSL certificates (acme.sh, DNS-01)"
      puts ""
      puts VoIPAppz::Colors.yellow("Run without --dry-run to execute")
    end

    private def deploy!
      config = load_config
      host, user, password, key_path, port = resolve_params(config)
      dest_domain = destination.try(&.domain) || ""
      domain = dest_domain.empty? ? (config.try(&.domain).try(&.name) || "") : dest_domain
      ssl_enabled = config.try(&.ssl).try(&.enabled) || false
      ssl_email = config.try(&.ssl).try(&.email) || config.try(&.domain).try(&.email) || ""

      remote = VoIPAppz::SSHRunner.new(host, user, password, key_path, port)

      puts VoIPAppz::Colors.bold("Deploying VoIPAppz to #{host}")
      puts "  User:   #{user}:#{port}"
      puts "  Domain: #{domain.empty? ? "(none)" : domain}"
      puts "  SSL:    #{ssl_enabled ? "acme.sh (DNS-01)" : "disabled"}"
      puts ""

      if skip_provision?
        puts VoIPAppz::Colors.yellow("1/9 + 2/9 Provisioning skipped (--skip-provision: host already bootstrapped — docker present, user in docker group)")
      else
        step("1/9 Installing Packages") do
          ssh_run!(host, user, "apt-get update -qq", password, key_path, port)
          # curl is required by the Kamal-style docker install below; sqlite3 for
          # the kamailio subcommand (reads kamailio.db via the host client); the
          # rest are operator conveniences.
          ssh_run!(host, user, "apt-get install -y curl ca-certificates git jq make openssl gnupg sqlite3", password, key_path, port)
        end

        step("2/9 Installing Docker (Kamal way: get.docker.com)") do
          # Same provisioning as `kamal server bootstrap`, in Crystal — see
          # VoIPAppz::Bootstrap. Idempotent: skips if docker is already present.
          ssh_run!(host, user, VoIPAppz::Bootstrap.install_docker_cmd, password, key_path, port)
          ssh_run!(host, user, VoIPAppz::Bootstrap.enable_docker_cmd, password, key_path, port)
          ssh_run!(host, user, VoIPAppz::Bootstrap.add_user_to_docker_group_cmd(user), password, key_path, port)
        end
      end

      step("3/9 Creating Directories") do
        # Wrap in bash -c so mkdir + chown BOTH run under one sudo — ssh_run! only
        # sudo-prefixes the first command in an `A && B` chain, else mkdir makes
        # /opt/va as root and the (unprivileged) chown then fails.
        ssh_run!(host, user, "bash -c 'mkdir -p /opt/va/secrets /opt/va/certs /opt/va/config /opt/va/switch/recordings /opt/va/switch/copied && chown -R #{user}:#{user} /opt/va'", password, key_path, port)
        # Generate self-signed cert immediately so Kong can start
        ssh_run!(host, user, "test -f /opt/va/certs/server.crt || openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /opt/va/certs/server.key -out /opt/va/certs/server.crt -subj '/CN=localhost'", password, key_path, port)
      end

      step("4/9 Uploading Files") do
        project_dir = VoIPAppz::SecretsHelper.project_dir
        self.class.deploy_files.each do |local, remote|
          local_path = File.join(project_dir, local)
          if File.exists?(local_path)
            # Create remote directory if needed
            remote_dir = File.dirname(remote)
            ssh_run!(host, user, "mkdir -p #{remote_dir}", password, key_path, port)

            exit_code, _ = VoIPAppz::SSH.upload(host, user, local_path, "/tmp/#{File.basename(local)}", password, key_path, port)
            if exit_code == 0
              ssh_run!(host, user, "mv /tmp/#{File.basename(local)} #{remote}", password, key_path, port)
              print "."
            else
              puts VoIPAppz::Colors.yellow("\n   Warning: failed to upload #{local}")
            end
          else
            puts VoIPAppz::Colors.yellow("\n   Missing: #{local}")
          end
        end
        ssh_run!(host, user, "chmod +x /opt/va/*.sh 2>/dev/null || true", password, key_path, port)
        puts ""
      end

      if skip_provision?
        puts VoIPAppz::Colors.yellow("5/9 Firewall skipped (--skip-provision: host firewall managed externally)")
      else
        step("5/9 Configuring Firewall") do
          FIREWALL_PORTS.each do |fw_port|
            ssh_run!(host, user, "which ufw && ufw allow #{fw_port} || echo 'No ufw, skipping'", password, key_path, port)
          end
          ssh_run!(host, user, "which ufw && echo 'y' | ufw enable || echo 'No ufw, skipping'", password, key_path, port)
        end
      end

      step("6/9 Secret files (shipped, consistent with .env)") do
        # The pgEdge postgres image + compose read the docker-secret FILES;
        # db-init / web / pgcat read the SAME values from .env. They MUST match.
        # `setup` writes both from one source (SecretsHelper), so the LOCAL
        # secrets/*.txt already match the LOCAL .env we shipped in step 4 — so
        # just ship those files verbatim. Never regenerate random values on the
        # node (postgres would init from a random file ≠ .env's VA_POSTGRES_PASSWORD
        # → auth failure; that was the pbx20 bug), and never parse .env through a
        # shell here (ssh_run! sudo-wraps the whole command, so a `v=$(...)`
        # assignment is swallowed by sudo and never reaches the redirect).
        project_dir = VoIPAppz::SecretsHelper.project_dir
        %w[postgres_password freeswitch_password s3_key s3_secret nats_token].each do |file|
          local_path = File.join(project_dir, "secrets", "#{file}.txt")
          unless File.exists?(local_path)
            puts VoIPAppz::Colors.yellow("\n   Missing local secret: secrets/#{file}.txt (run `voipappz setup`)")
            next
          end
          exit_code, _ = VoIPAppz::SSH.upload(host, user, local_path, "/tmp/#{file}.txt", password, key_path, port)
          if exit_code == 0
            ssh_run!(host, user, "mv /tmp/#{file}.txt /opt/va/secrets/#{file}.txt && chmod 0444 /opt/va/secrets/#{file}.txt", password, key_path, port)
            print "."
          else
            puts VoIPAppz::Colors.yellow("\n   Warning: failed to upload secret #{file}.txt")
          end
        end
        puts ""
      end

      step("7/9 Detecting Host IPs") do
        exit_code, public_ip = VoIPAppz::SSH.run(host, user, "curl -sf --max-time 5 https://ifconfig.me || curl -sf --max-time 5 https://api.ipify.org || echo #{host}", password, key_path, port, capture: true)
        public_ip = public_ip.strip
        public_ip = host if public_ip.empty?

        # Detect THIS node's primary internal IP (the source addr of its default
        # route). The shipped .env carries the operator's LOCAL machine IP, which
        # the node does not have — host-net services (kamailio) then fail to bind
        # it ("Cannot assign requested address"). So patch the internal IP to the
        # node's real one. Bridge services are unaffected (they use docker DNS
        # names), but VA_DB_ADDRESS/VA_APP_INTERNAL_IP_ADDRESS feed host-net binds.
        _, internal_ip = VoIPAppz::SSH.run(host, user, "ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1", password, key_path, port, capture: true)
        internal_ip = internal_ip.strip
        internal_ip = public_ip if internal_ip.empty?

        # Detect the node's docker group GID. host-net telegraf runs as
        # `telegraf:${VA_DOCKER_GID}` to read /var/run/docker.sock for the docker
        # input; a wrong GID → "permission denied … docker.sock" and it
        # crash-loops. The socket's group GID varies per host/distro, so read it
        # off the node rather than guessing the 999 default.
        _, docker_gid = VoIPAppz::SSH.run(host, user, "stat -c '%g' /var/run/docker.sock 2>/dev/null", password, key_path, port, capture: true)
        docker_gid = docker_gid.strip
        puts "   Public IP:   #{public_ip}"
        puts "   Internal IP: #{internal_ip}"
        puts "   Docker GID:  #{docker_gid}" unless docker_gid.empty?

        # Update .env with detected IPs (public → advertised/external; internal →
        # host-net bind address for kamailio et al.)
        ssh_run!(host, user, "sed -i 's/VA_APP_ADDRESS=.*/VA_APP_ADDRESS=#{public_ip}/' /opt/va/.env 2>/dev/null || true", password, key_path, port)
        ssh_run!(host, user, "sed -i 's/VA_APP_EXTERNAL_IP_ADDRESS=.*/VA_APP_EXTERNAL_IP_ADDRESS=#{public_ip}/' /opt/va/.env 2>/dev/null || true", password, key_path, port)
        ssh_run!(host, user, "sed -i 's/VA_APP_INTERNAL_IP_ADDRESS=.*/VA_APP_INTERNAL_IP_ADDRESS=#{internal_ip}/' /opt/va/.env 2>/dev/null || true", password, key_path, port)
        ssh_run!(host, user, "sed -i 's/VA_DB_ADDRESS=.*/VA_DB_ADDRESS=#{internal_ip}/' /opt/va/.env 2>/dev/null || true", password, key_path, port)
        unless docker_gid.empty?
          ssh_run!(host, user, "grep -q '^VA_DOCKER_GID=' /opt/va/.env && sed -i 's/VA_DOCKER_GID=.*/VA_DOCKER_GID=#{docker_gid}/' /opt/va/.env || echo 'VA_DOCKER_GID=#{docker_gid}' >> /opt/va/.env", password, key_path, port)
        end

        # Set the domain env vars. VA_DOMAIN is what acme.sh issues for (and
        # what the -d flag in step 9 uses); VA_SSL_EMAIL is the LE account
        # email. Kong reads neither — it only serves certs/server.*.
        unless domain.empty?
          ssh_run!(host, user, "grep -q VA_DOMAIN /opt/va/.env && sed -i 's/VA_DOMAIN=.*/VA_DOMAIN=#{domain}/' /opt/va/.env || echo 'VA_DOMAIN=#{domain}' >> /opt/va/.env", password, key_path, port)
          ssh_run!(host, user, "grep -q VA_SSL_EMAIL /opt/va/.env && sed -i 's/VA_SSL_EMAIL=.*/VA_SSL_EMAIL=#{ssl_email}/' /opt/va/.env || echo 'VA_SSL_EMAIL=#{ssl_email}' >> /opt/va/.env", password, key_path, port)
        end
      end

      step("8/9 Starting Services") do
        # Self-signed placeholders so TLS terminators boot BEFORE acme.sh issues
        # the real cert (kamailio's tls.so SIGSEGVs and Kong won't start without a
        # cert; step 9 can't install until they're up). acme.sh /
        # `voipappz cert --sync` overwrites these with the LE cert on a real domain. Generated here —
        # BEFORE compose up — because kamailio starts in this step.
        #   certs/server.{crt,key} → Kong    certs/tls.{crt,key} → kamailio
        {"server", "tls"}.each do |name|
          ssh_run!(host, user,
            "test -f /opt/va/certs/#{name}.crt || openssl req -x509 -nodes -days 365 -newkey rsa:2048 " \
            "-keyout /opt/va/certs/#{name}.key -out /opt/va/certs/#{name}.crt -subj '/CN=localhost' 2>/dev/null; " \
            "chmod 0444 /opt/va/certs/#{name}.crt /opt/va/certs/#{name}.key 2>/dev/null || true",
            password, key_path, port)
        end

        registry_login(host, user, password, key_path, port)
        puts "   Pulling images..."
        # WITH the profile flags, like the local path. Without them this pulled
        # a different set of images than the `up` two lines below starts.
        ssh_run!(host, user, "bash -lc 'cd /opt/va && docker compose #{compose_flags(profiles(false))} pull'", password, key_path, port)
        puts "   Starting containers..."
        ssh_run!(host, user, "bash -lc 'cd /opt/va && docker compose #{compose_flags(profiles(false))} up -d'", password, key_path, port)
        puts "   Waiting for services to come up..."
        wait_for_services(remote, profiles(false))
      end

      step("9/9 SSL Certificate Setup") do
        if ssl_enabled && !domain.empty?
          # acme.sh owns SSL (DNS-01 via Cloudflare) — Kong just serves
          # certs/server.*. Issuance needs no inbound port, only the one-time
          # static CNAME _acme-challenge.<domain> -> _acme-challenge.<alias>.
          # Non-fatal: a missing CF token or CNAME must not fail the deploy —
          # the self-signed placeholder from step 8 keeps TLS up, and the
          # operator can re-run `voipappz cert --issue` once DNS is in place.
          puts "   Issuing #{domain} via acme.sh (DNS-01)..."
          # Driven through docker directly rather than the remote CLI — the
          # binary isn't guaranteed to be on the node's PATH at this point.
          # acme.sh exits 2 for "cert still valid, skipped", which is success
          # here; only >2 is a real failure. The install step then (re)points
          # the cert at certs/server.* and installs the tls.* mirror reloadcmd.
          acme_cmd = "bash -lc 'set -a; . /opt/va/.env 2>/dev/null; set +a; " \
                     "docker exec acmesh acme.sh --issue --dns \"${VA_ACME_DNS:-dns_cf}\" " \
                     "-d #{domain} --challenge-alias \"${VA_ACME_ALIAS:-acme.voipappz.io}\" " \
                     "--server letsencrypt; rc=$?; [ $rc -le 2 ] || exit $rc; " \
                     "docker exec acmesh acme.sh --install-cert -d #{domain} " \
                     "--fullchain-file /out/server.crt --key-file /out/server.key " \
                     "--reloadcmd \"cp /out/server.crt /out/tls.crt && cp /out/server.key /out/tls.key\"'"
          exit_code, output = VoIPAppz::SSH.run(host, user, acme_cmd, password, key_path, port, capture: true)
          if exit_code == 0
            # Kong re-reads KONG_SSL_CERT only on reload.
            ssh_run!(host, user, "docker exec kong kong reload 2>/dev/null || true", password, key_path, port)
            ssh_run!(host, user, "docker exec kamailio kamcmd tls.reload 2>/dev/null || true", password, key_path, port)
            puts "   #{VoIPAppz::Colors.green("Certificate issued and installed")}"
          else
            puts "   #{VoIPAppz::Colors.warning("acme.sh issuance did not complete — keeping the self-signed cert")}"
            puts VoIPAppz::Colors.dim(output.lines.last(5).join("\n")) unless output.strip.empty?
            puts "   #{VoIPAppz::Colors.dim("Fix DNS (CNAME _acme-challenge.#{domain}) / VA_CF_TOKEN, then: voipappz cert --issue")}"
          end
        else
          puts "   Generating self-signed certificate..."
          ssh_run!(host, user, "test -f /opt/va/certs/server.crt || openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /opt/va/certs/server.key -out /opt/va/certs/server.crt -subj '/CN=localhost'", password, key_path, port)
        end
      end

      verify!(remote, profiles(false))
      print_success(host, user, domain)
    end

    # `--profile x --profile y` for docker compose, from the same rule the
    # verification list uses so the two cannot disagree.
    private def compose_flags(profs : Array(String)) : String
      VoIPAppz::Services.compose_profiles_for(profs).map { |p| "--profile #{p}" }.join(" ")
    end

    # A deploy is done when the services are actually up, not when the commands
    # returned — the same contract the app's Kamal post-deploy hook enforces.
    # Services first: the table explains WHY a probe would fail. Both run
    # regardless of the other's result, so one failure does not mask the other.
    #
    # Probes are skipped for a profile with no HTTP plane. This used to be two
    # copies of the gate, and they had already drifted — the remote one probed
    # the API on :5000 even for a voip-only deploy, which has no API.
    private def verify!(runner : VoIPAppz::Runner, profs : Array(String)) : Nil
      services_ok = verify_deployment(runner, profs)
      probes_ok = profs.includes?("app") ? probe_endpoints(runner) : true
      return if services_ok && probes_ok
      STDERR.puts ""
      STDERR.puts VoIPAppz::Colors.red("Deploy FAILED verification — not reporting success.")
      exit 1
    end

    # Profiles for this deploy. Local defaults to the app plane; a remote target
    # is the switch box, which is what `voip` is for.
    private def profiles(local : Bool) : Array(String)
      requested = flags.profile.split(',').map(&.strip).reject(&.empty?)
      return requested unless requested.empty?
      local ? ["app"] : ["voip"]
    end

    # `docker compose ps --format json` emits NDJSON — one object per line.
    private def parse_compose_ps(output : String) : Hash(String, {String, String})
      states = {} of String => {String, String}
      output.each_line do |line|
        line = line.strip
        next if line.empty?
        begin
          obj = JSON.parse(line)
          name = obj["Service"]?.try(&.as_s) || next
          states[name] = {obj["State"]?.try(&.as_s) || "unknown",
                          obj["Status"]?.try(&.as_s) || "-"}
        rescue JSON::ParseException
          next
        end
      end
      states
    end

    private def service_ok?(svc : String, state : String, status : String) : Bool
      if VoIPAppz::Services::INIT_SERVICES.includes?(svc)
        # A one-shot container succeeds by EXITING 0; still running is fine too.
        state == "exited" ? status.includes?("(0)") : state == "running"
      else
        state == "running"
      end
    end

    # Poll until every expected service is up, instead of sleeping a fixed 60s.
    # A blind sleep is wrong in both directions: it wastes a minute on a fast
    # host, and silently proceeds to verification on a slow one.
    private def wait_for_services(runner : VoIPAppz::Runner, profs : Array(String),
                                  timeout : Int32 = 180, interval : Int32 = 5) : Bool
      # Hoisted: this cannot change between polls, and it was being rebuilt
      # (flat_map + two scans over the catalog + uniq) on all ~36 iterations.
      expected = VoIPAppz::Services.expected_for(profs)
      waited = 0
      loop do
        _, output = runner.in_project("docker compose ps --format json --all")
        states = parse_compose_ps(output)
        pending = expected.reject do |svc|
          state, status = states[svc]? || {"missing", "-"}
          service_ok?(svc, state, status)
        end
        return true if pending.empty?
        if waited >= timeout
          puts "   #{VoIPAppz::Colors.yellow("still not up after #{timeout}s")}: #{pending.join(", ")}"
          return false
        end
        puts "   waiting for #{pending.size} service(s)… #{VoIPAppz::Colors.dim(pending.first(4).join(", "))}"
        sleep interval.seconds
        waited += interval
      end
    end

    # Endpoint probes on the target, mirroring the app's Kamal post-deploy hook:
    # container state alone does not prove the HTTP plane works — a container
    # can be "running" while the process inside is broken.
    private def probe_endpoints(runner : VoIPAppz::Runner) : Bool
      puts VoIPAppz::Colors.bold("\nProbing endpoints...")
      api_port = ENV.fetch("VA_API_PORT", "5000")
      probes = [
        {"API /health", "http://127.0.0.1:#{api_port}/health", "200"},
        {"Kong admin", "http://127.0.0.1:8001/status", "200"},
      ]
      ok = true
      probes.each do |name, url, expect|
        _, out = runner.run("curl -s -o /dev/null -w '%{http_code}' --max-time 10 #{url} || echo 000")
        code = out.strip.lines.last?.try(&.strip) || "000"
        if code == expect
          puts "   #{VoIPAppz::Colors.green("ok")}   #{name} → #{code}"
        else
          puts "   #{VoIPAppz::Colors.red("FAIL")} #{name} → #{code} (expected #{expect})"
          ok = false
        end
      end
      ok
    end

    # Verify what actually came up, and GATE the deploy on it.
    #
    # This used to print a table and return, with `print_success` running
    # unconditionally afterwards — so a deploy where nothing started still
    # reported success. The per-service check was also wrong: it asked
    # `output.includes?("Up")` against the WHOLE `docker compose ps` blob rather
    # than that service's row, so a single running container turned every row
    # green. Two bugs that hid each other (the list also named "api", which is
    # not a compose service — it is `web` — so that row could never have
    # matched on its own).
    #
    # Now: parse `--format json` per service, compare against the Services
    # catalog (the same source `up` starts from, so the two cannot drift), and
    # return false when anything expected is missing.
    private def verify_deployment(runner : VoIPAppz::Runner, profs : Array(String)) : Bool
      puts VoIPAppz::Colors.bold("\nVerifying Deployment...")
      _, output = runner.in_project("docker compose ps --format json --all")

      states = parse_compose_ps(output)
      expected = VoIPAppz::Services.expected_for(profs)

      columns = [
        VoIPAppz::Table::Column.new("Service", 20),
        VoIPAppz::Table::Column.new("State", 12),
        VoIPAppz::Table::Column.new("Status", 28),
      ]

      missing = [] of String
      rows = expected.map do |svc|
        state, status = states[svc]? || {"missing", "-"}
        ok = service_ok?(svc, state, status)
        missing << svc unless ok
        [svc, ok ? VoIPAppz::Colors.green(state) : VoIPAppz::Colors.red(state), status]
      end

      puts VoIPAppz::Table.render(columns, rows, title: "Service Verification")

      if missing.empty?
        puts VoIPAppz::Colors.green("All #{expected.size} services healthy.")
        true
      else
        STDERR.puts VoIPAppz::Colors.red("#{missing.size} service(s) not running: #{missing.join(", ")}")
        # The hint has to match where it actually ran, or it sends the operator
        # to ssh into a box they are already sitting on.
        hint = if runner.local?
                 "docker compose logs --tail=50 #{missing.first}"
               else
                 "ssh #{runner.label.sub(":", " -p ")} 'cd #{runner.workdir} && docker compose logs --tail=50 #{missing.first}'"
               end
        STDERR.puts VoIPAppz::Colors.dim("  #{hint}")
        false
      end
    end

    private def print_success(host : String, user : String, domain : String = "")
      puts ""
      puts "=" * 70
      puts VoIPAppz::Colors.green("VOIPAPPZ DEPLOYED SUCCESSFULLY")
      puts "=" * 70

      display = domain.empty? ? host : domain

      puts VoIPAppz::Colors.bold("\nService Endpoints:")
      puts "  API Health:     https://#{display}/health"
      puts "  Admin Panel:    https://#{display}"
      puts "  Kong Admin:     http://#{host}:8001"
      puts "  PostgreSQL:     #{host}:5432"
      puts "  SIP:            #{host}:5060 (UDP/TCP)"
      puts "  SIP TLS:        #{host}:8443"
      puts "  OpenBao:        127.0.0.1:8200 (host-local only — never exposed)"

      puts VoIPAppz::Colors.bold("\nManagement:")
      puts "  ssh #{user}@#{host} 'cd /opt/va && docker compose ps'"
      puts "  ssh #{user}@#{host} 'cd /opt/va && docker compose logs -f'"
      puts "  ssh #{user}@#{host} 'cd /opt/va && ./voipappz secrets --bao-status'"
      puts ""
    end

    private def step(name : String, &)
      puts VoIPAppz::Colors.cyan("\n#{name}...")
      yield
      puts "   Done"
    end

    # Log in to the image registry on the target so private images pull.
    # Password from ENV VA_REGISTRY_PASSWORD (KAMAL_REGISTRY_PASSWORD still
    # accepted as a fallback for older callers), never committed. Runs as root
    # (sudo) so creds land in /root/.docker/config.json, matching the sudo'd
    # `docker compose pull`.
    private def registry_login(host : String, user : String, password : String?, key_path : String, port : Int32)
      reg_pw = ENV["VA_REGISTRY_PASSWORD"]? || ENV["KAMAL_REGISTRY_PASSWORD"]?
      reg_user = destination.try(&.registry_username) || "nirlevi"
      if reg_pw && !reg_pw.empty?
        puts "   Registry login as #{reg_user}..."
        ssh_run!(host, user, "bash -c 'echo #{reg_pw} | docker login -u #{reg_user} --password-stdin'", password, key_path, port)
      else
        puts VoIPAppz::Colors.yellow("   ⚠ VA_REGISTRY_PASSWORD not set — private images may fail to pull. Export it before deploy.")
      end
    end

    private def ssh_run!(host : String, user : String, command : String,
                         password : String?, key : String, port : Int32)
      prefix = password ? "echo '#{password}' | sudo -S " : "sudo "
      VoIPAppz::SSH.run!(host, user, "#{prefix}#{command}", password, key, port)
    end
  end
end
