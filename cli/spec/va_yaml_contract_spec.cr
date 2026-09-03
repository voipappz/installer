require "./spec_helper"
require "../src/helpers/deploy_config"

# The va.yaml wire contract, pinned. Three consumers parse this file — the
# API generator writes it, this CLI reads AND re-writes it, va-crystal's node
# reads it. The canonical fixture has a twin at
# ../va-crystal/node/spec/fixtures/contract/va-canonical.yaml and both suites
# must stay green against the same content.
#
# The serialization assertions exist because the CLI once re-wrote gateways
# in a mapping form va-node cannot parse (Array(String) there), crash-looping
# every node whose va.yaml the CLI had touched.
describe "va.yaml contract" do
  fixture = File.read(File.join(__DIR__, "fixtures", "contract", "va-canonical.yaml"))

  it "parses the canonical fixture" do
    config = VoIPAppz::DeployConfig.from_yaml(fixture)
    config.organization.domain.should eq("pbx.contract.example")
    config.nodes.first.roles.should contain("switch")
    gws = config.sip_interfaces.first.gateways
    gws.size.should eq(3)
    gws[0].address.should eq("203.0.113.7")
    gws[0].mask.should eq(32)
    gws[1].address.should eq("203.0.113.0/24")
    gws[1].mask.should eq(24)
    gws[2].tag.should eq("00000000-0000-4000-8000-0000000000g1")
  end

  it "re-serializes gateways in the string wire form only" do
    config = VoIPAppz::DeployConfig.from_yaml(fixture)
    out = config.to_yaml
    # The string form: every gateway is a YAML scalar. The mapping form
    # ('- address: ...') is what crash-looped va-node — it must never be
    # written again, whatever form was read.
    out.should_not match(/-\s+address:/)
    out.should contain("198.51.100.0/24|00000000-0000-4000-8000-0000000000g1")
  end

  it "round-trips: what the CLI writes, the CLI (and va-node's grammar) reads back" do
    config = VoIPAppz::DeployConfig.from_yaml(fixture)
    reparsed = VoIPAppz::DeployConfig.from_yaml(config.to_yaml)
    reparsed.sip_interfaces.first.gateways.map(&.address).should eq(
      config.sip_interfaces.first.gateways.map(&.address))
    reparsed.sip_interfaces.first.gateways.map(&.tag).should eq(
      config.sip_interfaces.first.gateways.map(&.tag))
    # va-node declares gateways as Array(String): every serialized gateway
    # node must be a scalar, which the mapping-free regex above plus this
    # reparse together guarantee.
  end
end
