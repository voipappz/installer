require "./spec_helper"
require "../src/helpers/sync_config"

describe VoIPAppz::SyncConfig do
  node_uuid = "45ea4132-9f29-47b7-a874-6e6f8efe6d69"

  current_yaml = <<-YAML
    nodes:
      - uuid: '#{node_uuid}'
        name: 'node-#{node_uuid}'
        type: switch
        roles: [switch]
        profile:
          ip_address_internal: '10.0.0.10'
          ip_address_external: '203.0.113.10'
          sip_port: '5060'
    sip_interfaces:
      - uuid: '78ee4fb6-cefd-46b5-9dbd-dfb5a6f64021'
        name: sofia
        node_uuid: '#{node_uuid}'
        profile:
          ip_address_internal: '10.0.0.10'
          ip_address_external: '203.0.113.10'
          ip_address_internal_int_sip: '10.0.0.10'
          ip_address_internal_ext_sip: '10.0.0.10'
          ip_address_internal_int_rtp: '10.0.0.10'
          ip_address_internal_ext_rtp: '10.0.0.10'
          ip_address_external_int_sip: '10.0.0.10'
          ip_address_external_ext_sip: '203.0.113.10'
          ip_address_external_int_rtp: '10.0.0.10'
          ip_address_external_ext_rtp: '203.0.113.10'
          port_internal: '5070'
          port_external: '5090'
    mothership:
      url: 'https://operator.example.test'
    broker:
      url: 'nats://broker.example.test:4222'
    env:
      SAFE_RUNTIME_FLAG: 'yes'
      VA_API_AUTHORIZATION: 'Basic must-not-survive'
    YAML

  # Mirrors the real VaYaml fallback for a node that was created with POST
  # /nodes but has no SipInterface record: uuid is null, customer data is
  # present, ports use the server's old fallback, and local control-plane keys
  # are absent.
  remote_yaml = <<-YAML
    organization:
      name: VoIPAppz
      profile:
        smtp_username: 'server-access-key'
        smtp_password: 'server-secret'
    nodes:
      - uuid: '#{node_uuid}'
        name: 'node-#{node_uuid}'
        type: switch
        roles: [switch]
        profile:
          ip_address_internal: '10.0.0.10'
          ip_address_external: '203.0.113.10'
    customers:
      - uuid: customer-owned-by-mothership
        name: customer
    sip_interfaces:
      - uuid:
        name: sofia
        node_uuid: '#{node_uuid}'
        profile:
          port_internal: '5080'
          port_external: '5090'
          ip_address_internal: '10.0.0.10'
          ip_address_external: '203.0.113.10'
        gateways:
          - '198.51.100.0/24|provider-uuid'
    acl:
      - name: domains
        default: deny
        allow: ['10.0.0.0/8']
    YAML

  it "round-trips a newly registered node without losing local control-plane data" do
    current = VoIPAppz::DeployConfig.from_yaml(current_yaml)
    merged = VoIPAppz::SyncConfig.merge(remote_yaml, current, node_uuid)
    serialized = merged.to_yaml

    merged.mothership.url.should eq("https://operator.example.test")
    merged.broker.url.should eq("nats://broker.example.test:4222")
    merged.env["SAFE_RUNTIME_FLAG"].should eq("yes")
    merged.env.has_key?("VA_API_AUTHORIZATION").should be_false
    merged.organization.profile.smtp_username.should be_empty
    merged.organization.profile.smtp_password.should be_empty
    serialized.should_not contain("server-access-key")
    serialized.should_not contain("server-secret")
    serialized.should_not match(/^customers:/m)
    merged.acl.first.name.should eq("domains")
  end

  it "repairs the API fallback into the complete fixed SIP layout" do
    current = VoIPAppz::DeployConfig.from_yaml(current_yaml)
    merged = VoIPAppz::SyncConfig.merge(remote_yaml, current, node_uuid)
    node = merged.nodes.first
    interface = merged.sip_interfaces.first

    interface.uuid.should eq("78ee4fb6-cefd-46b5-9dbd-dfb5a6f64021")
    interface.node_uuid.should eq(node_uuid)
    node.profile["sip_port"].should eq("5060")
    node.profile["port_internal"].should eq("5070")
    node.profile["port_external"].should eq("5090")
    interface.profile["port_internal"].should eq("5070")
    interface.profile["port_external"].should eq("5090")
    VoIPAppz::Topology::LEG_FIELDS.each do |key|
      node.profile[key]?.should_not be_nil
      interface.profile[key]?.should_not be_nil
    end
    interface.gateways.first.address.should eq("198.51.100.0/24")
  end

  it "generates a valid interface UUID when no local identity exists" do
    merged = VoIPAppz::SyncConfig.merge(remote_yaml, nil, node_uuid)
    merged.sip_interfaces.first.uuid.not_nil!.should match(
      /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    )
  end

  it "rejects a response for a different node" do
    expect_raises(ArgumentError, /does not contain requested node/) do
      VoIPAppz::SyncConfig.merge(remote_yaml, nil, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    end
  end
end
