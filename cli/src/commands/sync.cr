require "admiral"
require "../helpers/node_registration"
require "http/client"
require "openssl"
require "../helpers/colors"
require "../helpers/address_snapshot"
require "../helpers/deploy_config"
require "../helpers/dispatcher_list"
require "../helpers/docker"
require "../helpers/net_validation"
require "../helpers/sync_config"
require "../helpers/va_config"

module VoIPAppz::Commands
  class Sync < Admiral::Command
    define_help description: "Pull, validate, and apply the node YAML from the mothership API"

    define_flag api_url : String,
      description: "Mothership API base URL (overrides VA_API_URL)",
      default: ""

    define_flag node_uuid : String,
      description: "Node UUID (overrides VA_NODE_UUID)",
      default: ""

    define_flag dry_run : Bool,
      description: "Print the fetched YAML without writing to disk",
      default: false

    define_flag config_only : Bool,
      description: "Write config/va.yaml without applying it to running SIP services",
      default: false

    def run
      out_path = VoIPAppz::VaConfig.yaml_path(VoIPAppz::Docker.project_dir)
      current = File.exists?(out_path) ? VoIPAppz::DeployConfig.load(out_path) : nil
      api_url = flags.api_url
      api_url = ENV["VA_API_URL"]?.to_s if api_url.empty?
      api_url = current.try(&.mothership.url) || "" if api_url.empty?

      node_uuid = flags.node_uuid
      node_uuid = ENV["VA_NODE_UUID"]?.to_s if node_uuid.empty?
      if node_uuid.empty?
        node_uuid = current.try { |value| value.nodes.first?.try(&.uuid) } || ""
      end

      # Token-free: the node pulls its own config via the node_uuid-based switch
      # endpoint (same model as callcenter/sofia config) — no per-node API token.
      if api_url.empty? || node_uuid.empty?
        STDERR.puts VoIPAppz::Colors.error(
          "Missing config: VA_API_URL and VA_NODE_UUID must both be set (in .env or via flags)"
        )
        exit 1
      end

      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::GEAR} Sync node config from mothership")
      puts ""
      puts VoIPAppz::Colors.info("Node    : #{node_uuid}")
      puts VoIPAppz::Colors.info("API     : #{api_url}")
      puts ""

      yaml_body = fetch_config(api_url, node_uuid)
      config = merge_config!(yaml_body, current, node_uuid)
      validate_config!(config)

      if flags.dry_run
        puts VoIPAppz::Colors.step(1, "Dry-run — would write config/va.yaml:")
        puts config.to_yaml
        return
      end

      backup = VoIPAppz::VaConfig.write_yaml(config, VoIPAppz::Docker.project_dir)
      if backup
        label = VoIPAppz::Docker.local_exec? ? "Temporary container-local backup" : "Backed up previous config"
        puts VoIPAppz::Colors.info("#{label} → #{backup}")
      end

      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} node YAML updated")
      if flags.config_only
        puts VoIPAppz::Colors.info("Configuration saved; data-plane apply skipped (--config-only)")
      else
        apply_running_sip!
      end
    end

    private def fetch_config(api_url : String, node_uuid : String) : String
      uri = URI.parse(api_url)
      unless VoIPAppz::NetValidation.safe_mothership_transport?(uri.scheme, uri.host)
        STDERR.puts VoIPAppz::Colors.error(
          "Mothership API must use HTTPS (plain HTTP is allowed only on loopback)"
        )
        exit 1
      end
      # Same trust as registration: verify, or verify against the pinned chain
      # in ca-bundle.pem beside va.yaml / SSL_CERT_FILE (node_registration.cr).
      VoIPAppz::NodeRegistration.config_dir = File.dirname(File.expand_path(VoIPAppz::VaConfig.yaml_path(VoIPAppz::Docker.project_dir)))
      client = VoIPAppz::NodeRegistration.https_client(uri)
      client.read_timeout = 15.seconds

      # Token-free, node_uuid-based — same self-serve model as the rest of
      # /switch/api/crystal/* (callcenter/sofia config).
      path = "/switch/api/crystal/va_yaml/#{node_uuid}"
      headers = HTTP::Headers{"Accept" => "application/yaml"}

      puts VoIPAppz::Colors.step(1, "GET #{api_url}#{path}")

      response = client.get(path, headers: headers)

      unless response.status_code == 200
        STDERR.puts VoIPAppz::Colors.error(
          "API returned #{response.status_code}: #{response.body.strip[0..200]}"
        )
        exit 1
      end

      response.body
    rescue ex : Exception
      STDERR.puts VoIPAppz::Colors.error("Failed to reach API: #{ex.message}")
      exit 1
    end

    private def merge_config!(content : String, current : VoIPAppz::DeployConfig?,
                              node_uuid : String) : VoIPAppz::DeployConfig
      VoIPAppz::SyncConfig.merge(content, current, node_uuid)
    rescue ex : YAML::ParseException
      STDERR.puts VoIPAppz::Colors.error("Invalid YAML from API: #{ex.message}")
      exit 1
    rescue ex : ArgumentError
      STDERR.puts VoIPAppz::Colors.error("Invalid node configuration: #{ex.message}")
      exit 1
    end

    private def validate_config!(config : VoIPAppz::DeployConfig) : Nil
      rows = [] of VoIPAppz::AddressSnapshot::Row
      config.sip_interfaces.each do |sip_interface|
        # Same empty-tag default as the egress sync_address apply step — the
        # validation must accept exactly what apply will accept, or a YAML
        # passes here and then fails after config/va.yaml was already replaced.
        default_tag = "#{VoIPAppz::DispatcherList::MANAGED_PREFIX}#{sip_interface.name}/gw"
        sip_interface.gateways.each do |gateway|
          parsed = VoIPAppz::NetValidation.parse_cidr(gateway.address, 32)
          raise "invalid provider CIDR '#{gateway.address}'" unless parsed
          ip, mask = parsed
          tag = gateway.tag.empty? ? default_tag : gateway.tag
          rows << VoIPAppz::AddressSnapshot::Row.new(2, ip, mask, gateway.port, tag)
        end
        validate_trunks!(sip_interface)
      end
      VoIPAppz::AddressSnapshot.plan([] of VoIPAppz::AddressSnapshot::Row, rows, 2)
      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} generated YAML validated")
    rescue ex : YAML::ParseException
      STDERR.puts VoIPAppz::Colors.error("Invalid YAML from API: #{ex.message}")
      exit 1
    rescue ex
      STDERR.puts VoIPAppz::Colors.error("Invalid node configuration: #{ex.message}")
      exit 1
    end


    # Trunks are the outbound half of a peering and every one of these failures
    # is otherwise silent until a call is placed: FreeSWITCH parses sofia.conf,
    # accepts a malformed gateway, and the call simply does not complete. Refuse
    # the YAML instead, before it replaces a working config/va.yaml.
    private def validate_trunks!(sip_interface : VoIPAppz::SipInterfaceConfig) : Nil
      seen = Set(String).new
      sip_interface.trunks.each do |trunk|
        raise "trunk on interface '#{sip_interface.name}' has no name" if trunk.name.strip.empty?
        # The node renders the co-located kamailio relay as "SBC" and each
        # bare-IP peer as "SBC-<ip>". A trunk taking either name produces two
        # <gateway> elements with one name and FreeSWITCH keeps the last.
        if trunk.name == "SBC" || trunk.name.starts_with?("SBC-")
          raise "trunk name '#{trunk.name}' is reserved for the node's own SBC gateways"
        end
        raise "duplicate trunk name '#{trunk.name}'" unless seen.add?(trunk.name)

        # A trunk targets ONE host: a CIDR is meaningful for an ACL row and
        # meaningless as a proxy address.
        if trunk.address.includes?("/")
          raise "trunk '#{trunk.name}' address '#{trunk.address}' is a CIDR; a trunk targets a single host"
        end
        unless VoIPAppz::NetValidation.parse_cidr(trunk.address, 32)
          raise "trunk '#{trunk.name}' has invalid address '#{trunk.address}'"
        end

        port = trunk.port.strip
        unless (n = port.to_i?) && n > 0 && n < 65_536
          raise "trunk '#{trunk.name}' has invalid port '#{trunk.port}'"
        end

        # register=true with no username means FS registers as nobody, retries,
        # and the trunk sits in FAIL_WAIT — visible only in sofia status.
        if trunk.register && trunk.username.strip.empty?
          raise "trunk '#{trunk.name}' sets register: true but has no username"
        end
      end

      # Not fatal: an outbound-only trunk is legitimate. But when the peer is
      # expected to call BACK, its INVITEs hit kamailio's permissions ACL, which
      # is fed from `gateways` alone — so a trunk absent from that list gives a
      # working outbound call and a rejected inbound one, which reads as "the
      # trunk half-works" and is miserable to diagnose. Say so at sync time.
      covered = sip_interface.gateways.map(&.ip).to_set
      sip_interface.trunks.select(&.enabled).each do |trunk|
        next if covered.includes?(trunk.ip)
        puts VoIPAppz::Colors.yellow(
          "  trunk '#{trunk.name}' (#{trunk.ip}) is not in gateways — outbound will work, " \
          "inbound from this peer will be rejected by the address ACL")
      end
    end

    private def apply_running_sip! : Nil
      containers = VoIPAppz::Docker.running_kamailios
      if containers.empty?
        puts VoIPAppz::Colors.info("No running Kamailio service detected; YAML is ready for the next service start")
        return
      end

      executable = Process.executable_path || "voipappz"
      planes = containers.map { |container|
        VoIPAppz::Docker.ingress?(container) ? "ingress" : "egress"
      }.uniq

      planes.each do |plane|
        puts ""
        puts VoIPAppz::Colors.step(3, "Applying #{plane} configuration")
        status = Process.run(executable, ["sbc", plane, "sync"],
          chdir: VoIPAppz::Docker.project_dir,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit)
        unless status.success?
          STDERR.puts VoIPAppz::Colors.error("#{plane} synchronization failed (exit #{status.exit_code})")
          exit status.exit_code
        end
      end

      puts ""
      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} node configuration applied")
    end
  end
end
