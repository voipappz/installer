require "uri"
require "./deploy_config"

module VoIPAppz
  # THE VOIP CONTAINER'S ENVIRONMENT, DERIVED FROM va.yaml.
  #
  # One file per node, mounted at /opt/va.yaml, is the only per-node input.
  # Everything the SIP plane needs to know about ITSELF is in it — the uuid, the
  # addresses it binds and advertises, the port kamailio takes, the mothership
  # it reports to, the broker it reaches — so an s6 oneshot runs `voipappz env
  # --export` at container start and writes the result into
  # /run/s6/container_environment. kamailio, FreeSWITCH and the node then read
  # it through with-contenv without knowing where it came from.
  #
  # This module is the derivation, and nothing else: no file reading, no
  # process, no environment. That is what makes it testable without a container
  # — see cli/spec/node_env_spec.cr.
  #
  # WHAT IS NOT HERE: secrets. VA_FREESWITCH_PASSWORD and the two LICENSE_* keys
  # stay in the environment (or a secrets file), because va.yaml is world-
  # readable by construction — it is bind-mounted into services that run as a
  # non-root user, `write_yaml` chmods it 0644, and `voipappz checks` FAILS a
  # va.yaml with inline secrets. A key that must not be in that file cannot be
  # derived from it.
  module NodeEnv
    # Credentials that are valid only for one operator-initiated process. Even
    # if someone puts one under va.yaml's `env:` escape hatch, the boot-time
    # exporter must not turn the world-readable node file into a credential
    # store. Pass these with `docker exec -e ...` instead.
    PROCESS_ONLY_ENV_KEYS = ["VA_API_AUTHORIZATION"]

    # kamailio's SIP port. NOT FreeSWITCH's: they share one network namespace
    # in this image, so sofia_internal must sit elsewhere (CI puts it on 5070).
    # va.yaml carries it as node.profile.sip_port when it differs from 5060.
    KAMAILIO_SIP_PORT       = "5060"
    SOFIA_INTERNAL_SIP_PORT = "5070"
    SOFIA_EXTERNAL_SIP_PORT = "5090"
    DEFAULT_SIP_PORT        = KAMAILIO_SIP_PORT
    BROKER_PORT             = "4222"   # the broker lives on the mothership's host

    # Everything below is loopback INSIDE the container, and identical on every
    # node — kamailio's RPC, FreeSWITCH's ESL, the node's own port and the
    # config URL FreeSWITCH fetches over xml_curl. They are emitted for the same
    # reason the addresses are: so a compose file (or an installer, or nothing
    # at all) does not have to restate what the image already knows.
    KAMAILIO_TCP_PORT = "8090"
    FREESWITCH_PORT   = "8021"
    NODE_PORT         = "4000"
    HEP_PORT          = "9060"
    SIP_BIND          = "0.0.0.0"
    SUBSCRIBER_DB     = "/var/lib/kamailio/kamailio.db"

    # A profile value of "auto" is a placeholder `voipappz setup` resolves when
    # it WRITES va.yaml, against the interfaces of the host it ran on. Resolving
    # it again here would mean guessing from inside a container, so instead the
    # key is skipped: whatever the environment already holds stands, and a node
    # whose file still says "auto" fails loudly at kamailio's bind rather than
    # binding an address nobody chose.
    AUTO = "auto"

    # va_path is the path the node itself will read (VA_PATH), which is where
    # this file is MOUNTED, not where it was read from on the host.
    def self.from(config : DeployConfig, va_path : String = "/opt/va.yaml") : Hash(String, String)
      env = {} of String => String
      node = config.node

      uuid = node.uuid.strip
      unless uuid.empty?
        # Two names for one value: the node reads VA_NODE_UUID, FreeSWITCH's
        # xml_curl URL is built from NODE_UUID. A node with the wrong one
        # answers "Node not found" and FreeSWITCH quietly falls back to the
        # vanilla profiles baked into its image — which look healthy in
        # `sofia status`, so this is worth keeping in lockstep.
        env["VA_NODE_UUID"] = uuid
        env["NODE_UUID"] = uuid
      end

      internal = usable(node.profile["ip_address_internal"]?)
      external = usable(node.profile["ip_address_external"]?)

      # kamailio BINDS internal and ADVERTISES external. On a LAN box they are
      # the same address and va.yaml usually says so; when only one is given,
      # the other follows it rather than falling back to loopback — a loopback
      # default is precisely the masking that made the baked ENV a bug.
      internal ||= external
      external ||= internal

      env["VA_INTERNAL_IP_ADDRESS_STR"] = internal if internal
      if external
        env["VA_EXTERNAL_IP_ADDRESS_STR"] = external
        env["PUBLIC_IP_ADDR"] = external
      end

      env["VA_PORT"] = usable(node.profile["sip_port"]?) || DEFAULT_SIP_PORT

      # The loopback ports and the SIP bind address are constants on a normal
      # node, but a second node on the SAME host (a lab) must move every one
      # of them. `env:` in va.yaml is the override — read here so everything
      # DERIVED from a port (RPC URL, config URL, HEP listener) follows it,
      # instead of asking the file to restate five consistent values.
      kamailio_tcp_port = usable(config.env["VA_KAMAILIO_TCP_PORT"]?) || KAMAILIO_TCP_PORT
      node_port         = usable(config.env["PORT"]?) || NODE_PORT
      freeswitch_port   = usable(config.env["FREESWITCH_PORT"]?) || FREESWITCH_PORT
      hep_port          = usable(config.env["VA_HEP_PORT"]?) || HEP_PORT
      env["VA_SIP_BIND"] = usable(config.env["VA_SIP_BIND"]?) || SIP_BIND
      env["VA_KAMAILIO_TCP_PORT"] = kamailio_tcp_port
      env["VA_HEP_PORT"] = hep_port
      env["HEP_LISTEN_ADDR"] = "0.0.0.0:#{hep_port}"

      # ── the control plane ──
      api_url = config.mothership.url.strip.rstrip("/")
      unless api_url.empty?
        # Two names again, and both are read: the node and its mediators take
        # API_URL, FreeSWITCH's start.sh and this CLI take VA_API_URL.
        env["API_URL"] = api_url
        env["VA_API_URL"] = api_url
      end

      # The broker follows the mothership: the installer writes both when
      # they are missing — the mothership from VA_API_URL, the broker from the
      # mothership's HOST on 4222 — and a value already in the file always
      # wins. Deriving it here means a file that names only the mothership
      # boots the same node the installer would have written.
      nats_url = config.broker.url.strip
      if nats_url.empty? && !api_url.empty?
        if (host = URI.parse(api_url).host) && !host.empty?
          nats_url = "nats://#{host}:#{BROKER_PORT}"
        end
      end
      env["NATS_URL"] = nats_url unless nats_url.empty?

      # ── loopback, and the same on every node ──
      env["VA_PATH"] = va_path
      env["PORT"] = node_port
      env["VA_SUBSCRIBER_DB"] = SUBSCRIBER_DB
      env["VA_KAMAILIO_RPC_URL"] = "http://127.0.0.1:#{kamailio_tcp_port}/RPC"
      env["FREESWITCH_HOST"] = "127.0.0.1"
      env["FREESWITCH_PORT"] = freeswitch_port
      env["VA_FREESWITCH_PORT"] = freeswitch_port

      # FreeSWITCH's config source is the node next to it, never the cloud: it
      # is what lets a node keep serving registrations through a cloud blip.
      unless uuid.empty?
        config_url = "http://127.0.0.1:#{node_port}/switch/config?node_uuid=#{uuid}"
        env["VA_API_SWITCH_CONFIG_URL"] = config_url
        env["VA_API_CONFIG_URL"] = config_url
      end

      # ── whatever else this node needs, stated outright ──
      #
      # LAST, so it overrides every derived key: a node that must advertise
      # something the schema cannot express says so here and is obeyed. The
      # only thing above it is the container's own environment, which the
      # writer never overwrites.
      config.env.each do |key, value|
        key = key.strip
        next if key.empty?
        next if PROCESS_ONLY_ENV_KEYS.includes?(key)
        env[key] = value
      end

      env
    end

    # EVERYTHING THE PLANE NEEDS, CHECKED BEFORE ANY SERVICE STARTS.
    #
    # Returns the list of things wrong with a derived environment — empty when
    # the node can boot. `process` is the container's own environment (docker
    # -e / compose), which fills anything the file does not; `boot` adds the
    # process-only secrets the node dies without. Called by `voipappz env
    # --export` at boot (the va-env oneshot), so a bad va.yaml halts the
    # container with ONE report naming every problem, instead of kamailio
    # binding 0.0.0.0, FreeSWITCH advertising nothing and the node crashing
    # on a missing secret — three services, three different errors, all
    # from one missing address (2026-08-26).
    SOFIA_PORTS = {SOFIA_INTERNAL_SIP_PORT.to_i, SOFIA_EXTERNAL_SIP_PORT.to_i}
    UUID_SHAPE = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
    LICENSE_SECRETS = {"LICENSE_JWT_SECRET", "LICENSE_ENCRYPTION_KEY"}
    LICENSE_SECRET_MIN = 32

    def self.problems(env : Hash(String, String), process : Hash(String, String) = ENV.to_h, boot : Bool = false) : Array(String)
      out = [] of String
      get = ->(key : String) { (env[key]? || process[key]?).try(&.strip) }

      uuid = get.call("VA_NODE_UUID")
      if uuid.nil? || uuid.empty?
        out << "nodes[0].uuid is empty — every node needs one (voipappz setup generates it)"
      elsif !UUID_SHAPE.matches?(uuid)
        out << "nodes[0].uuid #{uuid.inspect} is not a uuid"
      end

      {"VA_INTERNAL_IP_ADDRESS_STR" => "ip_address_internal", "VA_EXTERNAL_IP_ADDRESS_STR" => "ip_address_external"}.each do |key, field|
        addr = get.call(key)
        if addr.nil? || addr.empty?
          out << "nodes[0].profile.#{field} is missing — kamailio binds and advertises it; loopback is not accepted"
        elsif loopback_or_unspecified?(addr)
          out << "nodes[0].profile.#{field} = #{addr} — a loopback/unspecified address reaches no phone and no carrier"
        end
      end

      port = get.call("VA_PORT")
      if port && !(1..65535).includes?(port.to_i? || 0)
        out << "nodes[0].profile.sip_port #{port.inspect} is not a port"
      elsif port && SOFIA_PORTS.includes?(port.to_i)
        # The commit "The example handed FreeSWITCH the port kamailio owns":
        # kamailio and a Sofia profile on one port is two binds, one wins,
        # and calls vanish on the way in.
        out << "nodes[0].profile.sip_port #{port} is a Sofia port (internal #{SOFIA_INTERNAL_SIP_PORT}, external #{SOFIA_EXTERNAL_SIP_PORT}) — kamailio needs its own (default #{DEFAULT_SIP_PORT})"
      end

      api = get.call("API_URL")
      if api.nil? || api.empty?
        out << "mothership.url is missing"
      elsif !api.starts_with?("https://") && !private_http?(api)
        out << "mothership.url #{api} must be https:// (plain http only to loopback or a private network)"
      end

      nats = get.call("NATS_URL")
      if nats.nil? || nats.empty?
        out << "broker.url is missing — the node's control plane is NATS (broker: url: nats://host:4222)"
      elsif !nats.starts_with?("nats://") && !nats.starts_with?("tls://")
        out << "broker.url #{nats} must be nats:// or tls://"
      end

      if boot
        LICENSE_SECRETS.each do |key|
          value = process[key]?.try(&.strip) || ""
          if value.empty?
            out << "#{key} is not set — pass it to the container (docker -e #{key}=… / compose environment); it is never read from va.yaml"
          elsif value.size < LICENSE_SECRET_MIN
            out << "#{key} is shorter than #{LICENSE_SECRET_MIN} characters"
          end
        end
      end

      out
    end

    # Plain http is tolerable where the wire cannot leave the box or the LAN:
    # loopback and RFC1918. Anything else carries the node's traffic to a
    # mothership in the clear. (Registration is stricter — it needs https
    # outside literal loopback, because it carries the operator credential.)
    private def self.private_http?(url : String) : Bool
      host = (URI.parse(url).host || "").downcase
      return true if host == "localhost" || host == "127.0.0.1" || host == "::1"
      return true if host.starts_with?("10.") || host.starts_with?("192.168.")
      if (m = host.match(/\A172\.(\d+)\./)) && (16..31).includes?(m[1].to_i)
        return true
      end
      false
    rescue
      false
    end

    private def self.loopback_or_unspecified?(addr : String) : Bool
      a = addr.strip.downcase
      a.starts_with?("127.") || a == "::1" || a == "0.0.0.0" || a == "::" || a == "localhost"
    end

    # Empty, whitespace and "auto" all mean "not configured here".
    private def self.usable(value : String?) : String?
      return nil if value.nil?
      value = value.strip
      return nil if value.empty? || value == AUTO
      value
    end
  end
end
