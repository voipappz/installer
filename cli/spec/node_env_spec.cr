require "./spec_helper"
require "../src/helpers/node_env"

# The voip container derives its whole environment from the one file mounted
# into it. These specs pin the derivation itself — no container, no s6, no
# docker — because the failure mode being guarded is silent: a wrong address
# does not crash, it makes kamailio advertise something unreachable and every
# call fail at media.
private def config_from(yaml : String) : VoIPAppz::DeployConfig
  VoIPAppz::DeployConfig.from_yaml(yaml)
end

# Distinct name: `crystal spec` compiles every file in this directory into one
# program, so a bare NODE_YAML would collide with the next spec that wants it.
NODE_ENV_YAML = <<-YAML
  nodes:
    - uuid: '45ea4132-9f29-47b7-a874-6e6f8efe6d69'
      name: 'Node1'
      roles: [app, switch]
      profile:
        ip_address_external: '203.0.113.10'
        ip_address_internal: '10.0.0.5'
  broker:
    url: 'nats://broker.example.com:4222'
  mothership:
    url: 'https://cloud.voipappz.io'
  YAML

describe VoIPAppz::NodeEnv do
  it "defines the collision-free production SIP port layout once" do
    VoIPAppz::NodeEnv::KAMAILIO_SIP_PORT.should eq "5060"
    VoIPAppz::NodeEnv::SOFIA_INTERNAL_SIP_PORT.should eq "5070"
    VoIPAppz::NodeEnv::SOFIA_EXTERNAL_SIP_PORT.should eq "5090"
  end

  it "binds internal and advertises external, straight from the file" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))

    env["VA_INTERNAL_IP_ADDRESS_STR"].should eq "10.0.0.5"
    env["VA_EXTERNAL_IP_ADDRESS_STR"].should eq "203.0.113.10"
    # kamailio's config reads the two substdefs; FreeSWITCH's ext-sip-ip reads
    # PUBLIC_IP_ADDR. Same address, and it has to stay the same one.
    env["PUBLIC_IP_ADDR"].should eq "203.0.113.10"
  end

  it "carries the node uuid under both names FreeSWITCH and the node use" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))

    env["VA_NODE_UUID"].should eq "45ea4132-9f29-47b7-a874-6e6f8efe6d69"
    env["NODE_UUID"].should eq env["VA_NODE_UUID"]
    env["VA_API_SWITCH_CONFIG_URL"].should contain "node_uuid=45ea4132-9f29-47b7-a874-6e6f8efe6d69"
    # FreeSWITCH's config source is the node beside it, never the cloud.
    env["VA_API_SWITCH_CONFIG_URL"].should start_with "http://127.0.0.1:4000/"
  end

  it "takes the mothership and the broker from the file" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))

    env["API_URL"].should eq "https://cloud.voipappz.io"
    env["NATS_URL"].should eq "nats://broker.example.com:4222"
  end

  it "defaults the mothership to the cloud when the file does not say" do
    env = VoIPAppz::NodeEnv.from(config_from("nodes: []\n"))
    env["API_URL"].should eq "https://cloud.voipappz.io"
  end

  it "the broker follows the mothership's host on 4222 when the file names none" do
    # The installer's rule: mothership from VA_API_URL, broker from that host
    # on 4222, a value already in the file always wins.
    env = VoIPAppz::NodeEnv.from(config_from("nodes: []\n"))
    env["NATS_URL"].should eq "nats://cloud.voipappz.io:4222"
    env = VoIPAppz::NodeEnv.from(config_from("nodes: []\nmothership:\n  url: 'https://ms.example.net:8443'\n"))
    env["NATS_URL"].should eq "nats://ms.example.net:4222"
    env = VoIPAppz::NodeEnv.from(config_from("nodes: []\nbroker:\n  url: 'nats://own.example.net:4222'\n"))
    env["NATS_URL"].should eq "nats://own.example.net:4222"
  end

  it "gives kamailio 5060 unless the file names another port" do
    VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))["VA_PORT"].should eq "5060"

    with_port = NODE_ENV_YAML.sub("ip_address_internal: '10.0.0.5'",
      "ip_address_internal: '10.0.0.5'\n      sip_port: '5080'")
    VoIPAppz::NodeEnv.from(config_from(with_port))["VA_PORT"].should eq "5080"
  end

  it "never invents 127.0.0.1 for an address the file does not carry" do
    # This is the whole reason the baked ENV block had to go: a loopback
    # default let a misconfigured node boot and bind the wrong thing quietly.
    env = VoIPAppz::NodeEnv.from(config_from("nodes: []\n"))

    env.has_key?("VA_INTERNAL_IP_ADDRESS_STR").should be_false
    env.has_key?("VA_EXTERNAL_IP_ADDRESS_STR").should be_false
  end

  it "lets one address stand in for the other — a LAN box has only one" do
    one = <<-YAML
      nodes:
        - uuid: 'u'
          name: 'Node1'
          roles: [switch]
          profile:
            ip_address_external: '192.168.1.40'
      YAML

    env = VoIPAppz::NodeEnv.from(config_from(one))
    env["VA_INTERNAL_IP_ADDRESS_STR"].should eq "192.168.1.40"
    env["VA_EXTERNAL_IP_ADDRESS_STR"].should eq "192.168.1.40"
  end

  it "treats 'auto' as unconfigured — it is resolved when the file is WRITTEN" do
    auto = NODE_ENV_YAML.sub("'10.0.0.5'", "'auto'").sub("'203.0.113.10'", "'auto'")
    env = VoIPAppz::NodeEnv.from(config_from(auto))

    env.has_key?("VA_INTERNAL_IP_ADDRESS_STR").should be_false
    env.has_key?("VA_EXTERNAL_IP_ADDRESS_STR").should be_false
  end

  it "derives NO secrets — va.yaml is 0644 and checked for exactly this" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))

    %w[VA_FREESWITCH_PASSWORD FREESWITCH_PASSWORD LICENSE_JWT_SECRET LICENSE_ENCRYPTION_KEY]
      .each { |key| env.has_key?(key).should be_false }
  end

  it "exports the env: map verbatim — the escape hatch for the other ~30 keys" do
    # kamailio, FreeSWITCH and the node read about thirty variables between
    # them, and nothing about a node's addresses implies VA_MONITOR_TOKEN.
    yaml = NODE_ENV_YAML + <<-EXTRA

      env:
        VA_MONITOR_TOKEN: 'abc123'
        FREESWITCH_ESL_POOL: '8'
      EXTRA

    env = VoIPAppz::NodeEnv.from(config_from(yaml))
    env["VA_MONITOR_TOKEN"].should eq "abc123"
    env["FREESWITCH_ESL_POOL"].should eq "8"
  end

  it "never exports the mothership operator credential from va.yaml" do
    yaml = NODE_ENV_YAML + <<-EXTRA

      env:
        VA_API_AUTHORIZATION: 'Basic test-only-value'
      EXTRA

    VoIPAppz::NodeEnv.from(config_from(yaml)).has_key?("VA_API_AUTHORIZATION").should be_false
  end

  it "lets env: override a derived key — the file is the operator's last word" do
    yaml = NODE_ENV_YAML + <<-EXTRA

      env:
        VA_PORT: '5070'
      EXTRA

    VoIPAppz::NodeEnv.from(config_from(yaml))["VA_PORT"].should eq "5070"
  end

  it "keeps the loopback layout constant on a normal node" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))
    env["PORT"].should eq "4000"
    env["VA_SIP_BIND"].should eq "0.0.0.0"
    env["VA_KAMAILIO_TCP_PORT"].should eq "8090"
    env["VA_HEP_PORT"].should eq "9060"
    env["HEP_LISTEN_ADDR"].should eq "0.0.0.0:9060"
    env["VA_KAMAILIO_RPC_URL"].should eq "http://127.0.0.1:8090/RPC"
    env["VA_FREESWITCH_PORT"].should eq "8021"
  end

  it "moves EVERYTHING derived from a port when env: moves the port — a second node on one host" do
    yaml = NODE_ENV_YAML + <<-EXTRA

      env:
        PORT: '4002'
        FREESWITCH_PORT: '8023'
        VA_KAMAILIO_TCP_PORT: '8092'
        VA_HEP_PORT: '9062'
        VA_SIP_BIND: '10.0.0.6'
      EXTRA

    env = VoIPAppz::NodeEnv.from(config_from(yaml))
    env["PORT"].should eq "4002"
    env["VA_SIP_BIND"].should eq "10.0.0.6"
    env["VA_KAMAILIO_RPC_URL"].should eq "http://127.0.0.1:8092/RPC"
    env["VA_API_SWITCH_CONFIG_URL"].should start_with "http://127.0.0.1:4002/"
    env["VA_FREESWITCH_PORT"].should eq "8023"
    env["FREESWITCH_PORT"].should eq "8023"
    env["VA_HEP_PORT"].should eq "9062"
    env["HEP_LISTEN_ADDR"].should eq "0.0.0.0:9062"
  end

  it "gives FreeSWITCH the mothership under the name ITS start.sh reads" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))
    env["VA_API_URL"].should eq env["API_URL"]
  end

  it "points VA_PATH at where the file is MOUNTED, not where it was read" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML), va_path: "/opt/va.yaml")
    env["VA_PATH"].should eq "/opt/va.yaml"
  end
end

# The boot preflight: one report of everything wrong, before any service
# starts. A node that halts with these lines is fixable from the message; a
# node that boots past them is three different failures in three logs.
describe "VoIPAppz::NodeEnv.problems" do
  secrets = {"LICENSE_JWT_SECRET" => "x" * 40, "LICENSE_ENCRYPTION_KEY" => "y" * 40}

  it "accepts the example node, at boot, with the secrets in the process" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))
    VoIPAppz::NodeEnv.problems(env, process: secrets, boot: true).should be_empty
  end

  # installer/va.yaml.example is NOT the CLI's file. It ships from va-crystal
  # beside install.sh, and the node app that boots from it is what should assert
  # it — so the example that executed it (and installer_example_spec.cr, which
  # did the same at length) moved there with the CLI's departure from that repo.
  # Reaching two directories up for another repo's file is the coupling that
  # made this suite need the whole checkout mounted.

  it "names every problem at once — uuid, both addresses, mothership, broker, both secrets" do
    env = VoIPAppz::NodeEnv.from(config_from(<<-YAML))
      nodes:
        - uuid: 'not-a-uuid'
          profile:
            ip_address_external: '127.0.0.1'
      mothership:
        url: 'http://cloud.example.com'
      YAML
    problems = VoIPAppz::NodeEnv.problems(env, process: {} of String => String, boot: true)
    problems.join("\n").should contain "not a uuid"
    problems.join("\n").should contain "ip_address_internal = 127.0.0.1"
    problems.join("\n").should contain "ip_address_external = 127.0.0.1"
    problems.join("\n").should contain "must be https://"
    problems.join("\n").should contain "LICENSE_JWT_SECRET is not set"
    problems.join("\n").should contain "LICENSE_ENCRYPTION_KEY is not set"
    problems.size.should eq 6
  end

  it "rejects 0.0.0.0 and a missing address, which is what kamailio binds when nothing resolves" do
    env = VoIPAppz::NodeEnv.from(config_from(<<-YAML))
      nodes:
        - uuid: '45ea4132-9f29-47b7-a874-6e6f8efe6d69'
          profile:
            ip_address_external: '0.0.0.0'
      broker:
        url: 'nats://b:4222'
      YAML
    problems = VoIPAppz::NodeEnv.problems(env, process: {} of String => String)
    problems.size.should eq 2
    problems.each(&.should(contain "0.0.0.0"))
  end

  it "lets the container's own environment fill what the file leaves out" do
    env = VoIPAppz::NodeEnv.from(config_from(<<-YAML))
      nodes:
        - uuid: '45ea4132-9f29-47b7-a874-6e6f8efe6d69'
          profile:
            ip_address_external: '203.0.113.10'
      YAML
    process = secrets.merge({"NATS_URL" => "nats://from-docker-e:4222"})
    VoIPAppz::NodeEnv.problems(env, process: process, boot: true).should be_empty
  end

  it "tolerates plain http to loopback or a private network, never to the internet" do
    {"http://127.0.0.1:4180" => 0, "http://172.23.0.1:4180" => 0, "http://192.168.1.5" => 0, "http://10.0.0.9:3000" => 0,
     "http://172.32.0.1" => 1, "http://cloud.example.com" => 1, "http://203.0.113.9" => 1}.each do |url, count|
      env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))
      env["API_URL"] = url
      VoIPAppz::NodeEnv.problems(env, process: {} of String => String).size.should eq(count), url
    end
  end

  it "does not demand the secrets when not booting — a dry export by hand needs none" do
    env = VoIPAppz::NodeEnv.from(config_from(NODE_ENV_YAML))
    VoIPAppz::NodeEnv.problems(env, process: {} of String => String, boot: false).should be_empty
    VoIPAppz::NodeEnv.problems(env, process: {"LICENSE_JWT_SECRET" => "short", "LICENSE_ENCRYPTION_KEY" => "z" * 40}, boot: true)
      .should eq ["LICENSE_JWT_SECRET is shorter than 32 characters"]
  end
end

describe "VoIPAppz::NodeEnv.problems — the port kamailio owns" do
  it "refuses a sip_port that is a Sofia port — the mistake the example once shipped" do
    env = VoIPAppz::NodeEnv.from(config_from(<<-YAML))
      nodes:
        - uuid: '45ea4132-9f29-47b7-a874-6e6f8efe6d69'
          profile:
            ip_address_external: '203.0.113.10'
            sip_port: '5070'
      broker:
        url: 'nats://b:4222'
      YAML
    problems = VoIPAppz::NodeEnv.problems(env, process: {} of String => String)
    problems.size.should eq 1
    problems[0].should contain "5070 is a Sofia port"
  end
end
