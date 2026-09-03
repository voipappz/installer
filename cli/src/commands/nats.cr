require "admiral"
require "json"
require "../helpers/nats_control"
require "../helpers/deploy_config"
require "../helpers/docker"
require "../helpers/va_config"

module VoIPAppz::Commands
  # NATS client for the node-scoped kamailio command subject. The CLI only
  # SENDS requests; the executor is va-crystal's node (KamailioExecutor).
  class Nats < Admiral::Command
    define_help description: "Send node-scoped kamailio commands over NATS (va-node executes)"
    register_sub_command request, type: NatsRequest

    def run
      puts help
    end
  end

  class NatsRequest < Admiral::Command
    define_help description: "Publish a command to node:<uuid>:kamailio.command.sync and print the reply"
    define_flag action : String, description: "One of: #{VoIPAppz::NatsControl::ACTIONS.join(", ")}", default: "dispatcher.sync"
    define_flag username : String, description: "subscriber.* actions: SIP username", default: ""
    define_flag domain : String, description: "subscriber.* actions: SIP domain", default: ""
    define_flag password : String, description: "subscriber.add/passwd: SIP password", default: ""
    define_flag url : String, description: "NATS URL (overrides VA_NATS_URL)", default: ""
    define_flag node_uuid : String, description: "Node UUID (overrides VA_NODE_UUID)", default: ""
    define_flag timeout : Int32, description: "Request timeout in seconds", default: 30

    def run
      config = local_config
      configured_uuid = config.try { |value| value.nodes.first?.try(&.uuid) } || ""
      body = VoIPAppz::NatsControl.payload(
        flags.action, flags.username, flags.domain, flags.password)
      reply = VoIPAppz::NatsControl.request(
        VoIPAppz::NatsControl.url(flags.url, config.try(&.broker.url) || ""),
        VoIPAppz::NatsControl.node_uuid(flags.node_uuid, configured_uuid),
        body,
        flags.timeout
      )
      puts reply
      parsed = JSON.parse(reply)
      exit 1 unless parsed["status"]?.try(&.as_s?) == "success"
    rescue ex
      STDERR.puts "NATS request failed: #{ex.message}"
      exit 1
    end

    private def local_config : VoIPAppz::DeployConfig?
      path = VoIPAppz::VaConfig.yaml_path(VoIPAppz::Docker.project_dir)
      File.exists?(path) ? VoIPAppz::DeployConfig.load(path) : nil
    end
  end
end
