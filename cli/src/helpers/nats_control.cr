require "json"
require "nats"
require "uri"

# NATS *client* for node-scoped kamailio commands. The executor lives in
# va-crystal's node (KamailioExecutor): it subscribes to
# `node:<uuid>:kamailio.command.sync`, owns the kamailio DB mount, applies the
# change, reloads kamailio over RPC, and replies. The CLI only publishes a
# request on that subject and prints the reply — it never executes commands
# received over the bus (the old `nats listen` executor is gone by design).
module VoIPAppz::NatsControl
  extend self

  # Actions va-node's KamailioExecutor serves. Client-side gate only — the
  # executor revalidates; this exists to fail fast with a clear message.
  ACTIONS = %w[dispatcher.sync subscriber.add subscriber.passwd subscriber.remove subscriber.list]

  def url(override : String = "", configured : String = "") : String
    value = first_nonempty(override, ENV["VA_NATS_URL"]?, ENV["NATS_URL"]?, configured)
    raise "VA_NATS_URL is required" if value.empty?
    value
  end

  def node_uuid(override : String = "", configured : String = "") : String
    value = first_nonempty(override, ENV["VA_NODE_UUID"]?, ENV["NODE_UUID"]?, configured)
    raise "VA_NODE_UUID is required" if value.empty?
    value
  end

  private def first_nonempty(*values : String?) : String
    values.each do |value|
      next unless value
      return value unless value.empty?
    end
    ""
  end

  # Same subject KamailioExecutor.setup subscribes to in va-crystal.
  def subject(node_uuid : String) : String
    "node:#{node_uuid}:kamailio.command.sync"
  end

  def validate_action!(action : String) : Nil
    raise "unsupported action: #{action} (known: #{ACTIONS.join(", ")})" unless ACTIONS.includes?(action)
  end

  def payload(action : String, username : String = "", domain : String = "", password : String = "") : String
    validate_action!(action)
    body = {} of String => String
    body["action"] = action
    body["username"] = username unless username.empty?
    body["domain"] = domain unless domain.empty?
    body["password"] = password unless password.empty?
    body.to_json
  end

  def request(url : String, node_uuid : String, body : String, timeout : Int32) : String
    client = ::NATS::Client.new(URI.parse(url))
    response = client.request(subject(node_uuid), body, timeout: timeout.seconds)
    raise "no NATS responder for #{subject(node_uuid)} — is va-node running?" unless response
    response.data_string.to_s
  ensure
    client.try(&.close)
  end
end
