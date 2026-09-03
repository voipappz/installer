require "./spec_helper"
require "../src/helpers/deploy_config"

# Trunks are the OUTBOUND half of a peering (see TrunkConfig). The CLI does not
# author them — the mothership does — but every sync round-trips the document
# through this parser, so anything it drops is silently deleted from the node's
# config on the next sync. That is the regression these guard.
describe VoIPAppz::TrunkConfig do
  yaml = <<-YAML
    nodes: []
    sip_interfaces:
      - uuid: '78ee4fb6-cefd-46b5-9dbd-dfb5a6f64021'
        name: sofia
        node_uuid: '45ea4132-9f29-47b7-a874-6e6f8efe6d69'
        profile: {}
        gateways:
          - "198.51.100.77/32|00000000-0000-4000-8000-000000000077"
          - "10.0.0.1"
        trunks:
          - name: peer-pbx
            uuid: '00000000-0000-4000-8000-000000000020'
            address: 203.0.113.20
            port: "5080"
            codecs: PCMU,PCMA
            ptime: 20
            maxptime: 30
    YAML

  it "parses trunks alongside gateways" do
    config = VoIPAppz::DeployConfig.from_yaml(yaml)
    si = config.sip_interfaces.first
    si.gateways.size.should eq(2)
    trunk = si.trunks.first
    trunk.name.should eq("peer-pbx")
    trunk.address.should eq("203.0.113.20")
    # The port is the whole reason this type exists — a trunk to a peer off
    # 5060 cannot be expressed as a gateway string.
    trunk.port.should eq("5080")
    trunk.ptime.should eq(20)
    trunk.maxptime.should eq(30)
  end

  it "round-trips trunks through a write" do
    config = VoIPAppz::DeployConfig.from_yaml(yaml)
    reparsed = VoIPAppz::DeployConfig.from_yaml(config.to_yaml)
    trunk = reparsed.sip_interfaces.first.trunks.first
    trunk.name.should eq("peer-pbx")
    trunk.port.should eq("5080")
    trunk.ptime.should eq(20)
  end

  # The regression that made every CLI-written va.yaml crash-loop va-node:
  # gateways must stay SCALAR STRINGS. Adding trunks as a mapping beside them
  # must not tempt gateways into the same shape.
  it "keeps gateways scalar while trunks are mappings" do
    written = VoIPAppz::DeployConfig.from_yaml(yaml).to_yaml
    written.should contain("- 198.51.100.77/32|00000000-0000-4000-8000-000000000077")
    written.should contain("trunks:")
    written.should contain("name: peer-pbx")
  end

  it "defaults trunks to empty when absent" do
    minimal = "nodes: []\nsip_interfaces:\n  - name: sofia\n    node_uuid: x\n    profile: {}\n"
    VoIPAppz::DeployConfig.from_yaml(minimal).sip_interfaces.first.trunks.should be_empty
  end
end
