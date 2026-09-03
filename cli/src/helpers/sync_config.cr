require "set"
require "./deploy_config"
require "./va_config"

module VoIPAppz::SyncConfig
  extend self

  # The mothership owns dynamic node data (organization, gateways and ACLs),
  # while the installed node owns its control-plane addresses and process-only
  # environment. Merge those two halves before replacing the one local YAML.
  # This also repairs the API's derived, UUID-less Sofia fallback into the
  # complete collision-free layout the runtime requires.
  def merge(remote_yaml : String, current : DeployConfig?, node_uuid : String) : DeployConfig
    config = DeployConfig.from_yaml(remote_yaml)
    unless config.nodes.size == 1
      raise ArgumentError.new("generated YAML must describe exactly one node")
    end
    node = config.nodes.find { |candidate| candidate.uuid.downcase == node_uuid.downcase } ||
           raise ArgumentError.new("generated YAML does not contain requested node #{node_uuid}")

    if current
      preserve_local_sections!(config, current)
      preserve_local_node_profile!(node, current, node_uuid)
      preserve_fallback_interface!(config, current, node_uuid)
    end

    internal = node.profile["ip_address_internal"]? || ""
    external = node.profile["ip_address_external"]? || ""
    unless NetValidation.usable_node_ipv4?(internal) && NetValidation.usable_node_ipv4?(external)
      raise ArgumentError.new("generated YAML node addresses must be non-loopback IPv4 addresses")
    end

    # The endpoint returns one requested node. Put it first explicitly because
    # the runtime schema and VaConfig helpers intentionally operate on this box.
    config.nodes = [node]
    VaConfig.prepare_runtime_node!(config, internal)
    VaConfig.configure_node_network!(
      config,
      internal,
      external,
      Set{internal},
      replace_leg_ips: false
    )
    NodeEnv::PROCESS_ONLY_ENV_KEYS.each { |key| config.env.delete(key) }
    # The API's VaYaml response includes the full organization profile. SMTP
    # credentials belong to the mothership and must never be copied into the
    # node's world-readable va.yaml.
    config.organization.profile.smtp_username = ""
    config.organization.profile.smtp_password = ""
    config
  end

  private def preserve_local_sections!(config : DeployConfig, current : DeployConfig) : Nil
    config.mothership = current.mothership
    config.broker = current.broker
    config.env = current.env.dup
    config.license = current.license
    config.secrets = current.secrets
    config.deploy = current.deploy
    config.domain = current.domain
    config.ssl = current.ssl
    config.acl = current.acl if config.acl.empty?
  end

  # Old server records may predate the complete port/topology profile. The
  # local wizard already chose those values, so use them only to fill missing
  # server keys; values the mothership actually returned still win.
  private def preserve_local_node_profile!(node : NodeConfig, current : DeployConfig,
                                           node_uuid : String) : Nil
    local = current.nodes.find { |candidate| candidate.uuid.downcase == node_uuid.downcase }
    return unless local
    local.profile.each { |key, value| node.profile[key] ||= value }
  end

  # VaYaml derives an interface with uuid: null when no SipInterface record
  # exists. Retain this node's durable local interface identity and topology,
  # while keeping remote gateways and any explicit remote profile values.
  private def preserve_fallback_interface!(config : DeployConfig, current : DeployConfig,
                                           node_uuid : String) : Nil
    config.sip_interfaces.each do |remote|
      next unless remote.uuid.nil? || remote.uuid.to_s.empty?
      local = current.sip_interfaces.find do |candidate|
        candidate.node_uuid.downcase == node_uuid.downcase && candidate.name == remote.name
      end
      next unless local
      remote.uuid = local.uuid
      local.profile.each { |key, value| remote.profile[key] ||= value }
    end
  end
end
