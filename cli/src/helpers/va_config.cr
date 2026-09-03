require "yaml"
require "./deploy_config"
require "./net_validation"
require "./node_env"
require "./secrets"
require "./topology"

module VoIPAppz::VaConfig
  VA_YAML = "config/va.yaml"

  # Inside the production container the host's node file is mounted at
  # $VA_PATH. On a development checkout it remains config/va.yaml under the
  # resolved project. Every reader and writer must select the same file.
  def self.yaml_path(project_dir : String) : String
    configured = ENV["VA_PATH"]?.try(&.strip)
    configured && !configured.empty? ? configured : File.join(project_dir, VA_YAML)
  end

  # Load va.yaml from project directory, returning a DeployConfig
  def self.load(project_dir : String) : DeployConfig
    path = yaml_path(project_dir)
    if File.exists?(path)
      DeployConfig.load(path)
    else
      DeployConfig.new
    end
  end

  # Give a fresh node its durable identity and collision-free SIP layout. This
  # is pure configuration work: callers decide how addresses are obtained and
  # when the resulting document is written.
  def self.prepare_node!(config : DeployConfig, detected_ip : String,
                         new_roles : Array(String) = ["app", "switch"]) : NodeConfig
    if config.nodes.empty?
      node = NodeConfig.new
      node.uuid = ""
      node.name = ""
      node.type = "switch"
      node.roles = new_roles
      node.profile = {
        "ip_address_external" => detected_ip,
        "ip_address_internal" => detected_ip,
        "eventsocket_address" => detected_ip,
      }
      config.nodes << node
    end

    node = config.nodes.first
    config.nodes.each { |entry| entry.profile["sip_port"] = NodeEnv::KAMAILIO_SIP_PORT }

    if config.sip_interfaces.empty?
      interface = SipInterfaceConfig.new
      interface.name = "sofia"
      config.sip_interfaces << interface
    end

    config.sip_interfaces.each do |interface|
      interface.profile["ip_address_internal"] ||= node.profile["ip_address_internal"]? || detected_ip
      interface.profile["ip_address_external"] ||= node.profile["ip_address_external"]? || detected_ip
      interface.profile["port_internal"] = NodeEnv::SOFIA_INTERNAL_SIP_PORT
      interface.profile["port_external"] = NodeEnv::SOFIA_EXTERNAL_SIP_PORT
    end

    resolve_auto!(config, detected_ip)
    node
  end

  # The production CLI runs inside the SIP image. Older installer examples
  # omit `type`, which DeployConfig reads as `app`; make the runtime identity
  # explicit without changing the host/development wizard's mixed-node model.
  def self.prepare_runtime_node!(config : DeployConfig, detected_ip : String) : NodeConfig
    if config.nodes.size > 1
      raise ArgumentError.new("a runtime va.yaml must describe exactly one node")
    end
    node = prepare_node!(config, detected_ip, new_roles: ["switch"])
    node.type = "switch"
    node.roles << "switch" unless node.roles.includes?("switch")
    # A runtime document describes this one box. Repair cloned/example files
    # where the node UUID changed but the Sofia link did not; otherwise the
    # node cannot find an interface and FreeSWITCH renders no usable profile.
    config.sip_interfaces.each { |interface| interface.node_uuid = node.uuid }
    node
  end

  # Apply the addresses selected by the runtime wizard to the whole local SIP
  # interface. In runtime mode the wizard is authoritative: stale per-leg
  # values from a cloned node must not survive merely because they were present.
  def self.configure_node_network!(config : DeployConfig, internal_ip : String,
                                   external_ip : String, local_ips : Set(String),
                                   replace_leg_ips : Bool = true) : Symbol
    node = config.nodes.first? || raise ArgumentError.new("va.yaml has no node")
    node.profile["ip_address_internal"] = internal_ip
    node.profile["ip_address_external"] = external_ip
    node.profile["eventsocket_address"] = internal_ip

    topology = Topology.detect(internal_ip, external_ip, local_ips)
    derived = Topology.derive_leg_ips(internal_ip, external_ip, topology)
    node.profile["port_internal"] = NodeEnv::SOFIA_INTERNAL_SIP_PORT
    node.profile["port_external"] = NodeEnv::SOFIA_EXTERNAL_SIP_PORT
    derived.each do |key, value|
      current = node.profile[key]?
      node.profile[key] = value if replace_leg_ips || current.nil? || current.empty?
    end
    config.sip_interfaces.each do |interface|
      interface.profile["ip_address_internal"] = internal_ip
      interface.profile["ip_address_external"] = external_ip
      derived.each do |key, value|
        current = interface.profile[key]?
        interface.profile[key] = value if replace_leg_ips || current.nil? || current.empty?
      end
    end

    validate_node_addresses!(config)
    topology
  end

  # Every address setup writes is later used as a SIP bind or advertised
  # address. Validate the complete document, not only nodes[0], so an old
  # loopback override cannot make local checks green while phones cannot reach
  # the node.
  def self.validate_node_addresses!(config : DeployConfig) : Nil
    raise ArgumentError.new("va.yaml has no node") if config.nodes.empty?
    raise ArgumentError.new("va.yaml has no SIP interface") if config.sip_interfaces.empty?

    config.nodes.each_with_index do |node, index|
      ["ip_address_internal", "ip_address_external"].each do |key|
        validate_address!(node.profile[key]?, "nodes[#{index}].profile.#{key}")
      end
    end

    keys = ["ip_address_internal", "ip_address_external"] + Topology::LEG_FIELDS
    config.sip_interfaces.each_with_index do |interface, index|
      keys.each do |key|
        validate_address!(interface.profile[key]?, "sip_interfaces[#{index}].profile.#{key}")
      end
    end
  end

  # Replace "auto" IP strings + fill empty UUIDs
  def self.resolve_auto!(config : DeployConfig, detected_ip : String) : Nil
    # Resolve IPs in nodes and sip_interfaces (existing method)
    config.resolve_ips!(detected_ip)

    # Generate UUIDs for nodes that don't have one
    config.nodes.each do |n|
      if n.uuid.empty?
        n.uuid = generate_uuid
      end
      # API node names are globally unique. The old literal "Node1" made the
      # second fresh install fail even though its UUID was unique.
      if n.name.strip.empty? || n.name == "Node1"
        n.name = "node-#{n.uuid}"
      end
    end

    # Generate UUIDs for SIP interfaces + link to first node
    first_node_uuid = config.nodes.first?.try(&.uuid) || ""
    config.sip_interfaces.each do |si|
      si.uuid = generate_uuid if si.uuid.nil? || si.uuid.to_s.empty?
      si.node_uuid = first_node_uuid if si.node_uuid.empty? && !first_node_uuid.empty?
    end
  end

  # Flatten va.yaml config into a Hash(String, String) suitable for .env
  # All config + secrets in one file — referenced by ${VAR} in docker-compose.yaml
  def self.to_env(config : DeployConfig, secrets : Hash(String, String)? = nil) : Hash(String, String)
    env = {} of String => String
    org = config.organization
    n = config.node

    # Node identity
    env["VA_NODE_UUID"] = n.uuid unless n.uuid.empty?
    hostname = `hostname 2>/dev/null`.strip
    hostname = "voipappz-node" if hostname.empty?
    env["VA_HOSTNAME"] = hostname

    # Organization
    env["VA_ORGANIZATION_NAME"] = org.name
    env["VA_DOMAIN"] = org.domain
    # Let's Encrypt account email — passed to acme.sh as --accountemail (see
    # the `acmesh` compose service, which already expected VA_SSL_EMAIL but
    # never had it written here).
    env["VA_SSL_EMAIL"] = org.email
    env["VA_RACK_ENV"] = org.environment

    # Network — from first node's profile
    external_ip = n.profile["ip_address_external"]? || "127.0.0.1"
    internal_ip = n.profile["ip_address_internal"]? || "127.0.0.1"
    env["VA_APP_EXTERNAL_IP_ADDRESS"] = external_ip
    env["VA_APP_INTERNAL_IP_ADDRESS"] = internal_ip
    env["VA_APP_ADDRESS"] = internal_ip
    env["VA_DB_ADDRESS"] = internal_ip

    # Where the VOIP node is, as seen FROM THE APP NODE. Gatus runs on the app
    # plane and probes the voip node over the network (one endpoint against its
    # /health/node), so "127.0.0.1" is right only when both planes are one box.
    #
    # A SEPARATE voip node is one carrying the switch/voip role that is not
    # THIS node. When there is none, the roles are on this node — the combined
    # topology config/va.yaml.example describes — and its own address is the
    # correct answer, not a placeholder.
    #
    # Derived rather than asked, for the same reason firstboot derives the
    # node's own addresses from IMDS: a hand-entered address that is subtly
    # wrong points a health probe at a machine nobody is watching, and it looks
    # green until someone checks which box it reached.
    voip_node = config.nodes.find do |other|
      other.uuid != n.uuid &&
        (other.roles.includes?("switch") || other.roles.includes?("voip"))
    end
    env["VA_VOIP_ADDRESS"] =
      voip_node.try(&.profile["ip_address_internal"]?) || internal_ip

    # CPU
    cores = `nproc 2>/dev/null`.strip
    cores = "4" if cores.empty?
    env["VA_CPU_CORES"] = cores

    # Postgres
    env["VA_POSTGRES_USERNAME"] = "postgres"

    # S3 — consumed by `web` (on the bridge) → reach MinIO by service name.
    # (node/CLI hit MinIO at 127.0.0.1:9000 via the loopback publish separately.)
    env["VA_S3_REGION"] = "us-east-1"
    env["VA_S3_ENDPOINT"] = "http://minio:9000"

    # API
    # The API base the host-plane `node` container calls for directory /
    # callcenter / dialplan lookups (API_URL=${VA_API_URL:-} in compose).
    # Without it a fresh node has NO path from FreeSWITCH auth → node → API,
    # so every REGISTER dies 403 with nothing in FS's own logs. Host-net node
    # reaches the API on the loopback publish; a SaaS-attached override in
    # the environment is preserved.
    api_port = ENV["VA_API_PORT"]? || "5000"
    env["VA_API_URL"] = ENV["VA_API_URL"]? || "http://127.0.0.1:#{api_port}"

    # Bridge services talk to each other by CONTAINER NAME (Docker DNS) with no
    # env var. These two are the host-side exception: they're read by the
    # host-net `node` container and by this CLI (both on the host), which reach
    # the published ports over loopback — a bridge name would not resolve there.
    env["VA_INFLUXDB_HOST"] = "127.0.0.1"
    env["VA_INFLUXDB_PORT"] = "8181"
    env["VA_INFLUXDB_DATABASE"] = "telegraf"
    env["VA_NATS_HOST"] = "127.0.0.1"

    # SMTP (blank defaults silence compose warnings; fill in for real mail).
    #
    # ALERT_EMAIL_TO and SMTP_FROM default to the ORGANIZATION EMAIL asked for
    # at install, because Gatus refuses its email provider when either is blank
    # — "Ignoring provider=email due to error=from and to fields are required",
    # logged once at startup and never again. Blank defaults meant every node
    # shipped with alerting quietly switched off, which looks exactly like a
    # node with nothing to alert about.
    #
    # The HOST still has to be filled in; there is no guessing someone else's
    # mail server. Gatus reports what it accepted once at startup:
    # `docker logs va-gatus | grep configuredProviders` — [email] means alerting
    # works, [] means nothing will ever be sent.
    env["SMTP_FROM"] = org.email
    env["SMTP_HOST"] = ""
    env["SMTP_PORT"] = "587"
    env["SMTP_USERNAME"] = ""
    env["SMTP_PASSWORD"] = ""
    env["ALERT_EMAIL_TO"] = org.email

    # telegraf runs as `telegraf:${VA_DOCKER_GID}` so it can read
    # /var/run/docker.sock for its docker input. A wrong GID makes telegraf
    # exit with "permission denied ... docker.sock" on startup and crash-loop,
    # which silently kills the ENTIRE syslog pipeline — it is the collector
    # every service ships logs to. `deploy` detects this on the remote host;
    # nothing detected it locally, so a plain `setup` + `up` left the compose
    # default of 999 against a host GID that is rarely 999.
    if gid = docker_socket_gid
      env["VA_DOCKER_GID"] = gid
    end

    # The EGRESS's SIP port (compose: `VA_PORT: ${VA_SIP_PORT:-5060}`). There is
    # deliberately no VA_TLS_PORT beside it: SIP-TLS terminates on the ingress
    # now (2026-08-19), which reads VA_INGRESS_TLS_PORT (default 5062). A
    # VA_TLS_PORT here was answered by nothing in compose — an operator could
    # edit it and change no port at all.
    env["VA_SIP_PORT"] = "5060"

    # FreeSWITCH
    env["VA_FREESWITCH_PORT"] = "8021"
    env["VA_FREESWITCH_TAG"] = "node"
    env["VA_FS_MAX_SPS"] = "2000"
    env["VA_FS_MAX_SESSIONS"] = "5000"

    # Preserve API root-account UUIDs when setup regenerates .env. These are
    # bootstrap state consumed by the API's VA_ROOT allow-list, not generated
    # deployment configuration.
    if roots = (ENV["VA_ROOT"]? || ENV["ROOTS"]?)
      env["VA_ROOT"] = roots unless roots.empty?
    end

    # Events
    env["VA_EVENTS"] = "CUSTOM,CHANNEL_HANGUP_COMPLETE,CHANNEL_ORIGINATE,CHANNEL_ANSWER,CHANNEL_HANGUP,CHANNEL_EXECUTE_COMPLETE,CHANNEL_HANGUP_COMPLETE"

    # Secrets
    if secrets
      env["VA_POSTGRES_PASSWORD"] = secrets["postgres_password"] if secrets["postgres_password"]?
      env["VA_FREESWITCH_PASSWORD"] = secrets["freeswitch_password"] if secrets["freeswitch_password"]?
      env["VA_REDIS_PASSWORD"] = secrets["redis_password"] if secrets["redis_password"]?
      env["VA_NATS_TOKEN"] = secrets["nats_token"] if secrets["nats_token"]?
      # No VA_GATUS_* credential. Gatus is on the docker network: the API
      # reaches it by service name, compose publishes it on loopback for this
      # CLI, and nothing binds a host interface — so there is nothing exposed
      # for a password to protect. It had one for a day, and an empty value
      # made gatus refuse to start, which cost a node its alerting.
      env["VA_S3_KEY"] = secrets["s3_key"] if secrets["s3_key"]?
      env["VA_S3_SECRET"] = secrets["s3_secret"] if secrets["s3_secret"]?
      env["VA_LICENSE_ENCRYPTION_KEY"] = secrets["license_encryption_key"] if secrets["license_encryption_key"]?
      env["VA_LICENSE_JWT_SECRET"] = secrets["license_jwt"] if secrets["license_jwt"]?
      if sk = secrets["secret_key"]?
        env["VA_SECRET_KEY"] = sk      # compose (web) reads VA_SECRET_KEY
        env["VA_SECRET_KEY_BASE"] = sk # Rails-style alias for the same value
      end
      # API refuses to boot without a vault master key (mandatory secrets vault).
      env["VA_VAULT_MASTER_KEY"] = secrets["vault_master_key"] if secrets["vault_master_key"]?
      env["VA_INFLUX_TOKEN"] = secrets["influx_token"] if secrets["influx_token"]?
      # Same token powers Vector's write path and the CLI's query path.
      env["VA_MONITOR_TOKEN"] = secrets["influx_token"] if secrets["influx_token"]?

      # Derived URLs — clients read these directly so credentials stay
      # consolidated in one place. Loopback host because every container
      # uses network_mode: host.
      pg_pass = secrets["postgres_password"]? || "postgres"
      env["VA_DATABASE_URL"] = "postgres://postgres:#{pg_pass}@db:5432/voipappz"
      env["VA_DATABASE_KAMAILIO_URL"] = "postgres://postgres:#{pg_pass}@db:5432/kamailio"

      if redis_pw = secrets["redis_password"]?
        # Redis 6+ requires the username component (`default` is the
        # built-in superuser). Some clients reject the no-user form
        # `redis://:pw@host` with WRONGPASS; the explicit `default:` form
        # works for redis-cli, the Crystal redis client, and node-redis.
        env["VA_REDIS_URL"] = "redis://default:#{redis_pw}@127.0.0.1:6379/0"
      else
        env["VA_REDIS_URL"] = "redis://127.0.0.1:6379/0"
      end

      if nats_token = secrets["nats_token"]?
        # The local NATS server uses user/password auth (`user: "default"` +
        # `password: $VA_NATS_TOKEN` in nats.conf), NOT plain token auth — the
        # Crystal NATS client (jgaskins/nats, used by cable + node) only sends
        # `user`/`pass` on CONNECT, never `auth_token`. So the URL MUST include
        # the `default:` username; bare `nats://TOKEN@host` would be parsed by
        # the Crystal client as user=TOKEN with no password and rejected with
        # "Authorization Violation". Ruby's nats-pure tolerates both forms,
        # which is why the API stayed working while cable broke. See CLAUDE.md
        # "NATS auth: user/password, not token (Crystal client constraint)".
        # VA_NATS_URL = loopback, for the host-plane `node` (reaches local NATS
        # at 127.0.0.1:4222). VA_NATS_URL_API = same creds but the bridge service
        # name `nats`, for the bridge-networked `web` (docker DNS).
        env["VA_NATS_URL"] = "nats://default:#{nats_token}@127.0.0.1:4222"
        env["VA_NATS_URL_API"] = "nats://default:#{nats_token}@nats:4222"
      else
        env["VA_NATS_URL"] = "nats://127.0.0.1:4222"
        env["VA_NATS_URL_API"] = "nats://nats:4222"
      end

      # (VA_LAVINMQ_URL removed 2026-07-10 — LavinMQ retired, messaging on NATS)

      # Alert channel config (set by setup wizard step 4.5; empty by default
      # so Gatus's per-channel block stays inert until the operator opts in).
      {
        "alert_smtp_from"       => "SMTP_FROM",
        "alert_smtp_host"       => "SMTP_HOST",
        "alert_smtp_port"       => "SMTP_PORT",
        "alert_smtp_username"   => "SMTP_USERNAME",
        "alert_smtp_password"   => "SMTP_PASSWORD",
        "alert_email_to"        => "ALERT_EMAIL_TO",
        "alert_slack_webhook"   => "VA_ALERT_SLACK_WEBHOOK",
        "alert_discord_webhook" => "VA_ALERT_DISCORD_WEBHOOK",
        "alert_pagerduty_key"   => "VA_ALERT_PAGERDUTY_KEY",
        "alert_webhook_url"     => "VA_ALERT_WEBHOOK_URL",
      }.each do |secret_key, env_key|
        env[env_key] = secrets[secret_key] if secrets[secret_key]?
      end

      # TLS / acme.sh (setup wizard step 4). acme.sh is the ONLY cert authority
      # in the stack — Kong just serves certs/server.*. Without VA_CF_TOKEN the
      # acmesh daemon starts with an empty CF_Token and DNS-01 issuance can
      # never succeed, leaving the box on its self-signed placeholder forever.
      {
        "acme_cf_token" => "VA_CF_TOKEN",
        "acme_alias"    => "VA_ACME_ALIAS",
        "acme_dns"      => "VA_ACME_DNS",
      }.each do |secret_key, env_key|
        env[env_key] = secrets[secret_key] if secrets[secret_key]?
      end
    end

    env
  end

  # Group owner of the docker socket, as a string. nil when the socket is
  # absent (a non-docker host, or setup run before docker is installed) —
  # compose then falls back to its default.
  def self.docker_socket_gid : String?
    info = File.info?("/var/run/docker.sock")
    info ? info.group_id.to_s : nil
  rescue
    nil
  end

  # Write .env file from config (includes secrets when provided)
  # A VOIP NODE'S .env HOLDS ITS SECRETS AND NOTHING ELSE. The container reads
  # its configuration from va.yaml at boot (`va-env`, `voipappz env --export`),
  # so on a node the only values that must live outside the YAML are the ones
  # that must not be IN it: the three secrets `docker run -e` hands over. The
  # installer adds the image it runs and where the node reports; everything
  # else that used to land here — VA_POSTGRES_*, VA_RACK_ENV, SMTP_*, a vault
  # master key, generated S3 keys — was another machine's configuration on a
  # box with no database. The app plane (type "app") keeps the full set.
  NODE_ENV_KEYS = %w[VA_FREESWITCH_PASSWORD VA_LICENSE_JWT_SECRET VA_LICENSE_ENCRYPTION_KEY]

  def self.write_env(config : DeployConfig, project_dir : String, secrets : Hash(String, String)? = nil) : String?
    env = to_env(config, secrets)
    env = env.select { |k, _| NODE_ENV_KEYS.includes?(k) } if config.node.type == "switch"
    lines = env.to_a.sort_by(&.[0]).map { |k, v| "#{k}=#{v}" }
    content = lines.join("\n") + "\n"
    env_path = File.join(project_dir, ".env")
    backup = backup_existing(env_path)
    File.write(env_path, content)
    File.chmod(env_path, 0o600)
    backup
  end

  # Serialize config back to va.yaml (no secrets — they live in vault only)
  def self.write_yaml(config : DeployConfig, project_dir : String) : String?
    path = yaml_path(project_dir)
    # Setup is allowed to repair an existing node document. Strip a misplaced
    # operator credential before serializing so this writer can never preserve
    # it in the world-readable YAML. NodeRegistration separately rejects such
    # input when registration is attempted without running setup first.
    NodeEnv::PROCESS_ONLY_ENV_KEYS.each { |key| config.env.delete(key) }
    Dir.mkdir_p(File.dirname(path))
    temporary = "#{path}.tmp.#{Process.pid}"
    File.write(temporary, config.to_yaml)
    # 0644, not 0600: this file is bind-mounted into `web`, which runs as a
    # non-root app user. At 0600 every endpoint that reads it died with
    # "Permission denied - .../config/va.yaml", which surfaced as a 500 on
    # /custom/telegraf (so telegraf never got a config and the whole syslog
    # pipeline stayed dead) and on /auth/login. va.yaml holds no secrets —
    # checks.cr's check_va_yaml_inline_secrets enforces that, and secrets live
    # in .env (0600) and secrets/ (0700) — so it is safe to be world-readable.
    File.chmod(temporary, 0o644)
    backup = backup_existing(path, copy: true)
    begin
      File.rename(temporary, path)
    rescue ex : File::Error
      # A single-file Docker bind mount cannot be replaced with rename(2)
      # (EBUSY). Keep the mounted inode and copy the complete temporary file
      # into it; the backup above preserves the previous content.
      File.open(path, "w") do |destination|
        File.open(temporary) { |source| IO.copy(source, destination) }
        destination.flush
      end
      File.chmod(path, 0o644)
    end
    backup
  ensure
    File.delete(temporary) if temporary && File.exists?(temporary)
  end

  # Move an existing file aside before overwriting so an operator never silently
  # loses prior config. Returns the backup path so the caller can surface it,
  # or nil if no file existed. Idempotent: each call gets a unique timestamped
  # name, never clobbers a previous backup.
  def self.backup_existing(path : String, copy : Bool = false) : String?
    return nil unless File.exists?(path)
    ts = Time.utc.to_s("%Y%m%d-%H%M%S")
    base = "#{path}.bak.#{ts}"
    backup_path = base
    suffix = 0
    while File.exists?(backup_path)
      suffix += 1
      backup_path = "#{base}.#{suffix}"
    end
    copy ? File.copy(path, backup_path) : File.rename(path, backup_path)
    backup_path
  end

  private def self.validate_address!(value : String?, field : String) : Nil
    unless value && NetValidation.usable_node_ipv4?(value)
      raise ArgumentError.new("#{field} must be a non-loopback IPv4 address")
    end
  end

  private def self.generate_uuid : String
    hex = Random::Secure.hex(16)
    variant = "89ab"[Random::Secure.rand(4)]
    "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-#{variant}#{hex[17, 3]}-#{hex[20, 12]}"
  end
end
