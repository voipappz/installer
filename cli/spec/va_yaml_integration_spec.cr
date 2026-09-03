require "./spec_helper"

# Integration: the EXACT yaml shape the mothership `/api/customers/va_yaml/:node`
# endpoint generates must parse into the CLI's DeployConfig with every field the
# CLI + crystal node consume — node profile, sip_interface profile (the 8 leg
# IPs + ports), and gateways in the scalar "cidr|provider_uuid" form. Extra keys
# the endpoint emits (organization color/logo and the legacy customers section)
# must be tolerated but are not part of the node model.
describe "va_yaml endpoint → CLI DeployConfig integration" do
  # Mirrors the endpoint output (incl. extra keys that DeployConfig should ignore)
  yaml = <<-YAML
    organization:
      name: VoIPAppz
      language: en
      timezone: Asia/Jerusalem
      color: "#ffffff"
      logo_url: https://x/logo.png
      profile:
        domain: voipappz.io
    nodes:
    - uuid: 8224320f-31ce-456f-bbfe-91e1b8b5d0eb
      name: Node1
      type: app
      roles:
      - switch
      profile:
        ip_address_external: 199.203.162.92
        ip_address_internal: 10.57.47.197
    customers:
    - uuid: cust-1
      name: c1
      enabled: true
      node_uuid: 8224320f-31ce-456f-bbfe-91e1b8b5d0eb
      profile:
        domain: d.example.com
    sip_interfaces:
    - uuid: 66c0ce9f-00e4-4a1c-8b05-5ded27e2537d
      name: sofia
      node_uuid: 8224320f-31ce-456f-bbfe-91e1b8b5d0eb
      profile:
        port_internal: "5080"
        port_external: "5090"
        ip_address_internal_int_sip: 10.57.47.197
        ip_address_internal_ext_sip: 10.57.47.197
        ip_address_internal_int_rtp: 10.57.47.197
        ip_address_internal_ext_rtp: 10.57.47.197
        ip_address_external_int_sip: 10.57.47.197
        ip_address_external_ext_sip: 199.203.162.92
        ip_address_external_int_rtp: 10.57.47.197
        ip_address_external_ext_rtp: 199.203.162.92
      gateways:
      - "82.166.66.0/23|ae11e2db-4cce-4225-a986-c63b4fac1940"
    YAML

  config = VoIPAppz::DeployConfig.from_yaml(yaml)

  it "parses without error and tolerates the endpoint's extra keys" do
    config.organization.name.should eq("VoIPAppz")
    config.nodes.size.should eq(1)
    config.sip_interfaces.size.should eq(1)
    config.to_yaml.should_not match(/^customers:/m)
  end

  it "gives the node its profile (IPs the node + sofia config need)" do
    config.node.uuid.should eq("8224320f-31ce-456f-bbfe-91e1b8b5d0eb")
    config.node.profile["ip_address_internal"].should eq("10.57.47.197")
    config.node.profile["ip_address_external"].should eq("199.203.162.92")
  end

  it "gives the CLI the full sip_interface profile (all 8 leg IPs + ports)" do
    si = config.sip_interface
    si.name.should eq("sofia")
    si.node_uuid.should eq("8224320f-31ce-456f-bbfe-91e1b8b5d0eb")
    si.profile["port_internal"].should eq("5080")
    si.profile["port_external"].should eq("5090")
    si.profile["ip_address_internal_int_sip"].should eq("10.57.47.197")
    si.profile["ip_address_internal_ext_sip"].should eq("10.57.47.197")
    si.profile["ip_address_internal_int_rtp"].should eq("10.57.47.197")
    si.profile["ip_address_internal_ext_rtp"].should eq("10.57.47.197")
    si.profile["ip_address_external_int_sip"].should eq("10.57.47.197")
    si.profile["ip_address_external_ext_sip"].should eq("199.203.162.92")
    si.profile["ip_address_external_int_rtp"].should eq("10.57.47.197")
    si.profile["ip_address_external_ext_rtp"].should eq("199.203.162.92")
  end

  it "parses the provider gateway into ip / mask / tag (kamailio address + X-VA-Gateway)" do
    gw = config.sip_interface.gateways.first
    gw.ip.should eq("82.166.66.0")     # → kamailio address row ip
    gw.mask.should eq(23)              # → CIDR /23
    gw.tag.should eq("ae11e2db-4cce-4225-a986-c63b4fac1940")  # → address tag → X-VA-Gateway → ProviderCache.get_by_uuid
  end
end
