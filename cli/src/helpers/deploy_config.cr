require "yaml"

module VoIPAppz
  # Deploy configuration - va.yaml is the single source of truth.
  # All configuration (organization, secrets, nodes, deploy) lives here.
  #
  # Example:
  #   config = DeployConfig.load("config/va.yaml")
  #   config.organization.name  # => "VoIPAppz"
  #   config.secrets.source  # => "vault"
  #   config.deploy.host  # => "203.0.113.10"

  class OrganizationProfile
    include YAML::Serializable
    property smtp_address : String = ""
    property smtp_port : Int32 = 587
    property smtp_domain : String = ""
    property smtp_username : String = ""
    property smtp_password : String = ""
    property smtp_from : String = ""
    property smtp_authentication : String = "plain"
    def initialize; end
  end

  class OrganizationConfig
    include YAML::Serializable
    property name : String = "VoIPAppz"
    property domain : String = "voipappz.local"
    property email : String = "admin@voipappz.local"
    property language : String = "en"
    property timezone : String = "UTC"
    property environment : String = "production"
    property color : String = "#080808"
    property logo_url : String = ""
    property logo_icon : String = ""
    property profile : OrganizationProfile = OrganizationProfile.new
    def initialize; end
  end

  class SecretsConfig
    include YAML::Serializable
    property source : String = "vault"
    property vault_path : String = "secret/voipappz/secrets"
    def initialize; end
  end

  class DeployTarget
    include YAML::Serializable
    property host : String = ""
    property user : String = "root"
    property ssh_port : Int32 = 22
    property auth : String = "key"       # key | password
    property key : String = "~/.ssh/id_ed25519"
    property password : String = ""
    def initialize; end
  end

  class DomainConfig
    include YAML::Serializable
    property name : String = ""
    property dns : String = "manual"     # cloudflare | manual
    property email : String = ""
    def initialize; end
  end

  class SSLConfig
    include YAML::Serializable
    property enabled : Bool = true
    property provider : String = "acme.sh"  # acme.sh (DNS-01) owns SSL; Kong only serves the cert
    property email : String = ""
    def initialize; end
  end

  class NodeConfig
    include YAML::Serializable
    property uuid : String = ""
    property name : String = "Node1"
    property type : String = "app"
    property roles : Array(String) = ["app", "switch"]
    property profile : Hash(String, String) = {} of String => String
    def initialize; end
  end

  # An inbound-peer / carrier gateway. Accepts EITHER a bare string in va.yaml:
  #   "1.2.3.4"  |  "1.2.3.4/24"  |  "1.2.3.4/24|<tag>"
  # OR a structured mapping (the readable form):
  #   { address: 1.2.3.4/24, tag: <uuid>, port: 0 }
  # Backward compatible with the old plain-string list.
  class GatewayConfig
    property address : String = "" # ip or ip/mask (CIDR)
    property tag : String = ""
    property port : Int32 = 0

    def initialize(@address = "", @tag = "", @port = 0)
    end

    def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : GatewayConfig
      gw = GatewayConfig.new
      case node
      when YAML::Nodes::Scalar
        cidr, _, t = node.value.strip.partition("|")
        gw.address = cidr.strip
        gw.tag = t.strip
      when YAML::Nodes::Mapping
        node.nodes.each_slice(2) do |pair|
          next unless pair.size == 2
          k = pair[0].as?(YAML::Nodes::Scalar).try(&.value) || ""
          v = pair[1].as?(YAML::Nodes::Scalar).try(&.value) || ""
          case k
          when "address", "cidr", "ip" then gw.address = v.strip
          when "tag"                   then gw.tag = v.strip
          when "port"                  then gw.port = v.to_i? || 0
          when "mask"
            gw.address = "#{gw.address}/#{v.strip}" if !v.strip.empty? && !gw.address.includes?("/")
          end
        end
      else
        raise YAML::ParseException.new("gateway must be a string or a mapping", node.start_line, node.start_column)
      end
      gw
    end

    # Bare IP without the /mask suffix.
    def ip : String
      address.split("/", 2)[0]
    end

    # Mask bits; 32 when no CIDR suffix is present.
    def mask : Int32
      parts = address.split("/", 2)
      parts.size > 1 ? (parts[1].to_i? || 32) : 32
    end

    # ALWAYS serialize the compact string form ('ip', 'ip/mask', 'ip/mask|tag').
    # va-node's parser (SipInterfaceConfig in ../va-crystal) declares gateways
    # as Array(String): the mapping form this used to emit made every va.yaml
    # the CLI wrote crash-loop va-node with "Expected String, not mapping" —
    # caught live by the act full-environment run. The mapping form stays
    # ACCEPTED on input (above) but is never written; the string is the wire
    # contract all three consumers (API, CLI, va-node) agree on.
    # NOTE: port has no string encoding — it survives the CLI's own parse
    # (structured input) but is not round-tripped; nothing sets it today.
    def to_yaml(yaml : YAML::Nodes::Builder) : Nil
      value = tag.empty? ? address : "#{address}|#{tag}"
      yaml.scalar value
    end
  end

  # The OUTBOUND half of a peering, mirroring TrunkConfig in ../va-crystal
  # (node/node.cr) field for field — this type exists to round-trip that one.
  #
  # GatewayConfig above is the inbound half: an "ip/mask|tag" string whose only
  # consumer is kamailio's permissions ACL. It deliberately cannot express a
  # port (see the note on its to_yaml), which is exactly why placing a call
  # needed a second type rather than a wider string.
  #
  # Unlike gateways, this serializes as a MAPPING. That is safe where the
  # string form was not: `trunks` is a new key, and an older va-node ignores it
  # (its YAML::Serializable is non-strict) instead of crash-looping on a shape
  # it cannot parse. Never widen `gateways` the same way.
  class TrunkConfig
    include YAML::Serializable
    property name : String = ""
    property uuid : String = ""
    property address : String = ""
    property port : String = "5060"
    property register : Bool = false
    property username : String = ""
    property password : String = ""
    property realm : String = ""
    property from_domain : String = ""
    property context : String = "public"
    property codecs : String = ""
    property ptime : Int32? = nil
    property maxptime : Int32? = nil
    property enabled : Bool = true

    def initialize(@name = "", @address = "")
    end

    # Bare IP without any /mask suffix, for comparison against gateway rows.
    def ip : String
      address.split("/", 2)[0]
    end
  end

  class SipInterfaceConfig
    include YAML::Serializable
    # The mothership's derived fallback interface has no persisted UUID and is
    # serialized as YAML null. Sync normalizes it to a durable local UUID before
    # writing the node document.
    property uuid : String? = nil
    property name : String = "sofia"
    property node_uuid : String = ""
    property profile : Hash(String, String) = {} of String => String
    property gateways : Array(GatewayConfig) = [] of GatewayConfig
    property trunks : Array(TrunkConfig) = [] of TrunkConfig
    def initialize; end
  end

  class AclListConfig
    include YAML::Serializable
    property name : String = ""
    property default : String = "deny"
    property allow : Array(String) = [] of String
    property deny : Array(String) = [] of String
    def initialize; end
  end

  # WHERE THIS NODE'S CONTROL PLANE IS. Addresses, not secrets, which is why
  # they belong in va.yaml and not in the environment: a node is defined by the
  # mothership it reports to and the broker it reaches, exactly as it is defined
  # by the addresses it binds. Keeping them in compose meant every install had
  # to set them twice — once here for the CLI, once there for the container.
  #
  # Both default to something usable: the mothership to the cloud everyone
  # points at, the broker to nothing at all, because there is no sane default
  # for a broker and the node's NATS check is FATAL — better an empty value the
  # export skips (so an -e still wins) than a wrong one that looks configured.
  class MothershipConfig
    include YAML::Serializable
    property url : String = "https://cloud.voipappz.io"
    def initialize; end
  end

  class BrokerConfig
    include YAML::Serializable
    property url : String = ""
    def initialize; end
  end

  class LicenseConfig
    include YAML::Serializable
    property token : String = ""
    property version : String = "2.0"
    property issued_at : String = ""
    property checksum : String = ""
    def initialize; end
  end

  class DeployConfig
    include YAML::Serializable

    # Core sections
    property organization : OrganizationConfig = OrganizationConfig.new
    property secrets : SecretsConfig = SecretsConfig.new

    # Infrastructure
    property nodes : Array(NodeConfig) = [] of NodeConfig
    property sip_interfaces : Array(SipInterfaceConfig) = [] of SipInterfaceConfig
    property acl : Array(AclListConfig) = [] of AclListConfig
    property license : LicenseConfig? = nil

    # Control plane. Read by NodeEnv to derive API_URL / NATS_URL for the voip
    # container; unknown to va-node's own parser, which ignores keys it does
    # not declare, so adding them breaks no existing va.yaml.
    property mothership : MothershipConfig = MothershipConfig.new
    property broker : BrokerConfig = BrokerConfig.new

    # ESCAPE HATCH, and the reason one file can configure three services.
    #
    # kamailio, FreeSWITCH and the node between them read about thirty
    # variables, and no derivation rule will ever cover all of them — nothing
    # about a node's addresses implies VA_MONITOR_TOKEN or FREESWITCH_ESL_POOL.
    # So anything the schema does not model goes here and is exported after the
    # derived keys, overriding them unless it is explicitly process-only.
    #
    # NOT for secrets. This file is world-readable by construction (0644, bind-
    # mounted into services that run unprivileged) and `voipappz checks` fails a
    # va.yaml with inline secrets. Process-only credentials such as
    # VA_API_AUTHORIZATION are filtered by NodeEnv and rejected by registration;
    # `voipappz checks` also reports them as a hard failure.
    property env : Hash(String, String) = {} of String => String

    # Deploy sections
    property deploy : DeployTarget? = nil
    property domain : DomainConfig? = nil
    property ssl : SSLConfig? = nil

    def initialize; end

    def self.load(path : String) : DeployConfig
      from_yaml(File.read(path))
    end

    # First node, or create default
    def node : NodeConfig
      nodes.first? || NodeConfig.new
    end

    # First SIP interface, or create default
    def sip_interface : SipInterfaceConfig
      sip_interfaces.first? || SipInterfaceConfig.new
    end

    # Resolve "auto" values in node profile to actual IP
    def resolve_ips!(ip : String)
      nodes.each do |n|
        n.profile.each do |k, v|
          n.profile[k] = ip if v == "auto"
        end
        n.profile["ip_address_external"] ||= ip
        n.profile["ip_address_internal"] ||= ip
        n.profile["eventsocket_address"] ||= ip
      end
      sip_interfaces.each do |si|
        si.profile.each do |k, v|
          si.profile[k] = ip if v == "auto"
        end
      end
    end
  end
end
