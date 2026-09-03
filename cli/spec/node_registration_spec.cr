require "./spec_helper"
require "file_utils"
require "http/server"
require "../src/helpers/node_registration"
require "../src/helpers/va_config"

private NODE_UUID          = "00000000-0000-4000-8000-000000000002"
private SPEC_AUTHORIZATION = "Basic c3R1Yi1yb290OnN0dWItc2VjcmV0"

private record RegistrationRequest,
  method : String,
  path : String,
  authorization : String?,
  body : String

private def with_registration_server(handler : HTTP::Server::Context -> _, &)
  server = HTTP::Server.new { |context| handler.call(context) }
  port = server.bind_tcp("127.0.0.1", 0).port
  spawn { server.listen }
  20.times do
    begin
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue
      sleep 10.milliseconds
    end
  end
  begin
    yield "http://127.0.0.1:#{port}"
  ensure
    server.close
  end
end

private def registration_project(api_url : String,
                                 uuid : String = NODE_UUID,
                                 internal_ip : String = "10.0.0.10",
                                 external_ip : String = "203.0.113.10") : String
  project = File.tempname("va-registration-spec")
  Dir.mkdir_p(File.join(project, "config"))
  File.write(File.join(project, "config", "va.yaml"), <<-YAML)
    nodes:
      - uuid: #{uuid}
        name: local-node
        type: switch
        roles: [switch]
        profile:
          ip_address_internal: #{internal_ip}
          ip_address_external: #{external_ip}
          sip_port: "5060"
    sip_interfaces:
      - uuid: 00000000-0000-4000-8000-000000000003
        name: sofia
        node_uuid: #{uuid}
        profile:
          port_internal: "5070"
          port_external: "5090"
    mothership:
      url: #{api_url}
    broker:
      url: nats://broker.example:4222
    YAML
  project
end

private def response_node : String
  {
    uuid:    NODE_UUID,
    name:    "local-node",
    type:    "switch",
    roles:   ["switch"],
    profile: {
      "ip_address_internal" => "10.0.0.10",
      "ip_address_external" => "203.0.113.10",
      "sip_port"            => "5060",
    },
    source:   "database",
    editable: true,
  }.to_json
end

describe VoIPAppz::NodeRegistration do
  it "registers the exact node document produced by setup helpers" do
    requests = [] of RegistrationRequest
    handler = ->(context : HTTP::Server::Context) do
      body = context.request.body.try(&.gets_to_end) || ""
      requests << RegistrationRequest.new(context.request.method, context.request.path,
        context.request.headers["Authorization"]?, body)
      context.response.content_type = "application/json"
      if context.request.method == "GET"
        context.response.status_code = 404
        context.response.print %({"error":"not found"})
      else
        context.response.status_code = 201
        context.response.print body
      end
    end

    with_registration_server(handler) do |api_url|
      project = File.tempname("va-registration-seam-spec")
      Dir.mkdir_p(File.join(project, "config"))
      begin
        config = VoIPAppz::DeployConfig.new
        config.mothership.url = api_url
        node = VoIPAppz::VaConfig.prepare_runtime_node!(config, "10.0.0.10")
        VoIPAppz::VaConfig.configure_node_network!(
          config,
          "10.0.0.10",
          "203.0.113.10",
          Set{"10.0.0.10"},
          replace_leg_ips: true
        )
        VoIPAppz::VaConfig.write_yaml(config, project).should be_nil
        path = File.join(project, "config", "va.yaml")

        result = VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)

        result.operation.created?.should be_true
        result.node_uuid.should eq(node.uuid)
        requests.map(&.method).should eq(["GET", "POST"])
        payload = JSON.parse(requests.last.body).as_h
        payload["uuid"].as_s.should eq(node.uuid)
        payload["name"].as_s.should eq("node-#{node.uuid}")
        payload["type"].as_s.should eq("switch")
        payload["roles"].as_a.map(&.as_s).should eq(["switch"])
        payload["profile"]["sip_port"].as_s.should eq("5060")
        payload["profile"]["port_internal"].as_s.should eq("5070")
        payload["profile"]["port_external"].as_s.should eq("5090")
        VoIPAppz::Topology::LEG_FIELDS.each do |key|
          VoIPAppz::NetValidation.usable_node_ipv4?(payload["profile"][key].as_s).should be_true
        end
        requests.last.body.should_not contain("customers")

        written = VoIPAppz::DeployConfig.load(path)
        interface = written.sip_interfaces.first
        interface.profile["port_internal"].should eq("5070")
        interface.profile["port_external"].should eq("5090")
        VoIPAppz::Topology::LEG_FIELDS.each do |key|
          VoIPAppz::NetValidation.usable_node_ipv4?(interface.profile[key]).should be_true
        end
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "creates from only node data and passes Basic authorization verbatim" do
    requests = [] of RegistrationRequest
    handler = ->(context : HTTP::Server::Context) do
      body = context.request.body.try(&.gets_to_end) || ""
      requests << RegistrationRequest.new(context.request.method, context.request.path,
        context.request.headers["Authorization"]?, body)
      context.response.content_type = "application/json"
      if context.request.method == "GET"
        context.response.status_code = 404
        context.response.print %({"error":"not found"})
      else
        context.response.status_code = 201
        context.response.print response_node
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      path = File.join(project, "config", "va.yaml")
      original = File.read(path)
      begin
        result = VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)

        result.operation.created?.should be_true
        requests.map(&.method).should eq(["GET", "POST"])
        requests.map(&.path).should eq(["/api/nodes/#{NODE_UUID}", "/api/nodes"])
        requests.each { |request| request.authorization.should eq(SPEC_AUTHORIZATION) }
        payload = JSON.parse(requests.last.body).as_h
        payload.keys.sort.should eq(%w(name profile roles type uuid))
        requests.last.body.should_not contain("customer")
        requests.last.body.should_not contain(SPEC_AUTHORIZATION)
        File.read(path).should eq(original)
        Dir.glob("#{path}.bak.*").should be_empty
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "is idempotent by UUID: a re-run is a GET-only no-op" do
    requests = [] of RegistrationRequest
    exists = false
    handler = ->(context : HTTP::Server::Context) do
      body = context.request.body.try(&.gets_to_end) || ""
      requests << RegistrationRequest.new(context.request.method, context.request.path,
        context.request.headers["Authorization"]?, body)
      context.response.content_type = "application/json"
      if context.request.method == "GET" && exists
        context.response.print response_node
      elsif context.request.method == "GET"
        context.response.status_code = 404
        context.response.print %({"error":"not found"})
      else
        exists = true
        context.response.status_code = 201
        context.response.print response_node
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      path = File.join(project, "config", "va.yaml")
      begin
        first = VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)
        second = VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)
        first.operation.created?.should be_true
        second.operation.existing?.should be_true
        requests.map(&.method).should eq(["GET", "POST", "GET"])
        requests.last.body.should be_empty
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "leaves a node the mothership declares in its own va.yaml alone" do
    requests = [] of RegistrationRequest
    # What the API answers for a config-file node: no row, so no PATCH can win.
    owned = {
      uuid:     NODE_UUID,
      name:     "MTN-DB",
      type:     "db",
      roles:    [] of String,
      profile:  {} of String => String,
      source:   "va.yaml",
      editable: false,
    }.to_json
    handler = ->(context : HTTP::Server::Context) do
      body = context.request.body.try(&.gets_to_end) || ""
      requests << RegistrationRequest.new(context.request.method, context.request.path,
        context.request.headers["Authorization"]?, body)
      context.response.content_type = "application/json"
      if context.request.method == "GET"
        context.response.print owned
      else
        context.response.status_code = 406
        context.response.print %({"error":"comes from va.yaml"})
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      path = File.join(project, "config", "va.yaml")
      begin
        result = VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)
        result.operation.existing?.should be_true
        requests.map(&.method).should eq(["GET"])
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "updates the same UUID once when setup changed node data" do
    requests = [] of RegistrationRequest
    handler = ->(context : HTTP::Server::Context) do
      body = context.request.body.try(&.gets_to_end) || ""
      requests << RegistrationRequest.new(context.request.method, context.request.path,
        context.request.headers["Authorization"]?, body)
      context.response.content_type = "application/json"
      if context.request.method == "GET"
        stale = JSON.parse(response_node).as_h
        stale["profile"] = JSON.parse(%({"ip_address_internal":"10.0.0.99","ip_address_external":"203.0.113.99"}))
        context.response.print stale.to_json
      else
        context.response.print response_node
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      path = File.join(project, "config", "va.yaml")
      begin
        result = VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)
        result.operation.updated?.should be_true
        requests.map(&.method).should eq(["GET", "PATCH"])
        requests.last.path.should eq("/api/nodes/#{NODE_UUID}")
        JSON.parse(requests.last.body)["uuid"].as_s.should eq(NODE_UUID)
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "preserves server-owned profile fields when updating YAML-owned fields" do
    patched_profile = nil
    handler = ->(context : HTTP::Server::Context) do
      body = context.request.body.try(&.gets_to_end) || ""
      context.response.content_type = "application/json"
      if context.request.method == "GET"
        stale = JSON.parse(response_node).as_h
        profile = stale["profile"].as_h
        profile["ip_address_internal"] = JSON::Any.new("10.0.0.99")
        profile["server_managed"] = JSON::Any.new("preserve-me")
        context.response.print stale.to_json
      else
        patched_profile = JSON.parse(body)["profile"].as_h
        context.response.print body
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      begin
        result = VoIPAppz::NodeRegistration.register(
          File.join(project, "config", "va.yaml"), SPEC_AUTHORIZATION)

        result.operation.updated?.should be_true
        profile = patched_profile.not_nil!
        profile["server_managed"].as_s.should eq("preserve-me")
        profile["ip_address_internal"].as_s.should eq("10.0.0.10")
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "ignores server-owned profile metadata and role ordering on a repeated registration" do
    requests = [] of RegistrationRequest
    handler = ->(context : HTTP::Server::Context) do
      body = context.request.body.try(&.gets_to_end) || ""
      requests << RegistrationRequest.new(context.request.method, context.request.path,
        context.request.headers["Authorization"]?, body)
      existing = JSON.parse(response_node).as_h
      existing["roles"] = JSON.parse(%(["switch","app"]))
      profile = existing["profile"].as_h
      profile["server_managed"] = JSON::Any.new("preserved")
      context.response.content_type = "application/json"
      context.response.print existing.to_json
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      begin
        path = File.join(project, "config", "va.yaml")
        File.write(path, File.read(path).sub("roles: [switch]", "roles: [app, switch]"))
        result = VoIPAppz::NodeRegistration.register(
          path, SPEC_AUTHORIZATION)

        result.operation.existing?.should be_true
        requests.map(&.method).should eq(["GET"])
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "preserves a create validation error when the UUID still does not exist" do
    requests = [] of String
    handler = ->(context : HTTP::Server::Context) do
      requests << context.request.method
      if context.request.method == "GET"
        context.response.status_code = 404
        context.response.print %({"error":"not found"})
      else
        context.response.status_code = 406
        context.response.print({error: "duplicate node name #{SPEC_AUTHORIZATION}"}.to_json)
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      begin
        error = expect_raises(VoIPAppz::NodeRegistration::Error) do
          VoIPAppz::NodeRegistration.register(
            File.join(project, "config", "va.yaml"), SPEC_AUTHORIZATION)
        end
        error.message.to_s.should contain("duplicate node name")
        error.message.to_s.should contain("[REDACTED]")
        error.message.to_s.should_not contain(SPEC_AUTHORIZATION)
        requests.should eq(["GET", "POST", "GET"])
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "treats a conflict followed by the UUID appearing as a create race" do
    requests = [] of String
    handler = ->(context : HTTP::Server::Context) do
      requests << context.request.method
      context.response.content_type = "application/json"
      case requests.size
      when 1
        context.response.status_code = 404
        context.response.print %({"error":"not found"})
      when 2
        context.response.status_code = 409
        context.response.print %({"error":"conflict"})
      else
        context.response.print response_node
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      begin
        result = VoIPAppz::NodeRegistration.register(
          File.join(project, "config", "va.yaml"), SPEC_AUTHORIZATION)
        result.operation.existing?.should be_true
        requests.should eq(["GET", "POST", "GET"])
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "redacts authorization before bounding a long API error" do
    credentials = SPEC_AUTHORIZATION.partition(' ')[2]
    handler = ->(context : HTTP::Server::Context) do
      if context.request.method == "GET"
        context.response.status_code = 404
      else
        context.response.status_code = 422
        context.response.print({error: ("x" * 230) + SPEC_AUTHORIZATION}.to_json)
      end
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      begin
        error = expect_raises(VoIPAppz::NodeRegistration::Error) do
          VoIPAppz::NodeRegistration.register(
            File.join(project, "config", "va.yaml"), SPEC_AUTHORIZATION)
        end
        error.message.to_s.should_not contain(credentials)
        error.message.to_s.should_not contain(credentials[0, 8])
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end

  it "fails before requesting when Basic authorization is absent or malformed" do
    project = registration_project("http://127.0.0.1:1")
    path = File.join(project, "config", "va.yaml")
    begin
      {"", "Bearer not-basic", "Basic "}.each do |authorization|
        error = expect_raises(VoIPAppz::NodeRegistration::Error) do
          VoIPAppz::NodeRegistration.register(path, authorization)
        end
        error.message.to_s.should contain("VA_API_AUTHORIZATION")
      end
    ensure
      FileUtils.rm_rf(project)
    end
  end

  it "rejects a mothership credential stored in va.yaml" do
    project = registration_project("http://127.0.0.1:1")
    path = File.join(project, "config", "va.yaml")
    File.write(path, File.read(path) + <<-YAML)

      env:
        VA_API_AUTHORIZATION: 'Basic test-only-value'
      YAML
    begin
      error = expect_raises(VoIPAppz::NodeRegistration::Error) do
        VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)
      end
      error.message.to_s.should contain("must not contain VA_API_AUTHORIZATION")
    ensure
      FileUtils.rm_rf(project)
    end
  end

  it "rejects non-v4 UUIDs and loopback addresses before contacting the API" do
    projects = [
      registration_project("http://127.0.0.1:1", uuid: "00000000-0000-0000-0000-000000000002"),
      registration_project("http://127.0.0.1:1", internal_ip: "127.0.0.1"),
      registration_project("http://127.0.0.1:1", external_ip: "0.0.0.0"),
    ]
    begin
      projects.each do |project|
        expect_raises(VoIPAppz::NodeRegistration::Error) do
          VoIPAppz::NodeRegistration.register(File.join(project, "config", "va.yaml"), SPEC_AUTHORIZATION)
        end
      end
    ensure
      projects.each { |project| FileUtils.rm_rf(project) }
    end
  end

  it "rejects an app-default node when runtime setup was skipped" do
    project = registration_project("http://127.0.0.1:1")
    path = File.join(project, "config", "va.yaml")
    File.write(path, File.read(path)
      .sub("type: switch", "type: app")
      .sub("roles: [switch]", "roles: [app]"))
    begin
      error = expect_raises(VoIPAppz::NodeRegistration::Error) do
        VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)
      end
      error.message.to_s.should contain("type switch")
    ensure
      FileUtils.rm_rf(project)
    end
  end

  it "never sends root authorization over non-loopback HTTP" do
    projects = [
      registration_project("http://api.example.com"),
      registration_project("http://127.attacker.example"),
    ]
    begin
      projects.each do |project|
        error = expect_raises(VoIPAppz::NodeRegistration::Error) do
          VoIPAppz::NodeRegistration.register(File.join(project, "config", "va.yaml"), SPEC_AUTHORIZATION)
        end
        error.message.to_s.should contain("must use HTTPS")
        error.message.to_s.should_not contain(SPEC_AUTHORIZATION)
      end
    ensure
      projects.each { |project| FileUtils.rm_rf(project) }
    end
  end

  it "reports authorization failures without writing YAML or exposing credentials" do
    handler = ->(context : HTTP::Server::Context) do
      context.response.status_code = 403
      context.response.content_type = "application/json"
      context.response.print({error: "forbidden"}.to_json)
    end

    with_registration_server(handler) do |api_url|
      project = registration_project(api_url)
      path = File.join(project, "config", "va.yaml")
      original = File.read(path)
      begin
        error = expect_raises(VoIPAppz::NodeRegistration::Error) do
          VoIPAppz::NodeRegistration.register(path, SPEC_AUTHORIZATION)
        end
        error.message.to_s.should contain("authorization failed")
        error.message.to_s.should_not contain(SPEC_AUTHORIZATION)
        File.read(path).should eq(original)
        Dir.glob("#{path}.bak.*").should be_empty
      ensure
        FileUtils.rm_rf(project)
      end
    end
  end
end

# A TLS failure must say what failed and what fixes it. The raw OpenSSL line
# names neither the host nor the pin file, and there is no flag to suggest:
# the pin (ca-bundle.pem beside va.yaml, or SSL_CERT_FILE) is the whole answer.
describe "VoIPAppz::NodeRegistration TLS" do
  it "names the host, the cause and the pin as the remedy when nothing is pinned" do
    saved = ENV["SSL_CERT_FILE"]?
    ENV.delete("SSL_CERT_FILE")
    msg = VoIPAppz::NodeRegistration.tls_failure_message(URI.parse("https://10.135.18.114/api"),
      "SSL_connect: error:0A000086:SSL routines::certificate verify failed")
    msg.should contain "https://10.135.18.114: its certificate could not be verified"
    msg.should contain "save it as ca-bundle.pem next to va.yaml"
    msg.should contain "SSL_CERT_FILE=/path/to/chain.pem"
    msg.should_not contain "INSECURE"
    msg.should contain "openssl said: SSL_connect: error:0A000086"
  ensure
    saved ? (ENV["SSL_CERT_FILE"] = saved) : ENV.delete("SSL_CERT_FILE")
  end

  it "says the pin did not match when one is in use" do
    saved = ENV["SSL_CERT_FILE"]?
    ENV["SSL_CERT_FILE"] = "/work/config/ca-bundle.pem"
    msg = VoIPAppz::NodeRegistration.tls_failure_message(URI.parse("https://10.135.18.114/api"),
      "SSL_connect: error:0A000086:SSL routines::certificate verify failed")
    msg.should contain "does not match the pinned chain in /work/config/ca-bundle.pem"
  ensure
    saved ? (ENV["SSL_CERT_FILE"] = saved) : ENV.delete("SSL_CERT_FILE")
  end

  it "tells a plain-HTTP port apart from a bad certificate" do
    msg = VoIPAppz::NodeRegistration.tls_failure_message(URI.parse("https://10.0.0.5:5000/api"),
      "SSL_connect: error:0A00010B:SSL routines::wrong version number")
    msg.should contain "did not answer TLS on port 5000"
  end
end
