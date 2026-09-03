require "./spec_helper"
require "../src/helpers/deploy_destination"

# Kamal-style per-server destination files: one small committed file per PBX
# (config/deploy.<dest>.yml), loaded by `voipappz deploy -d <dest>`.
describe VoIPAppz::DeployDestination do
  it "parses a destination file; class defaults are the shared base" do
    d = VoIPAppz::DeployDestination.from_yaml(<<-YAML)
      host: 203.0.113.10
      user: ubuntu
      key: /opt/sw.key
      YAML
    d.host.should eq("203.0.113.10")
    d.user.should eq("ubuntu")
    d.key.should eq("/opt/sw.key")
    # defaults supplied by the class (the "base")
    d.ssh_port.should eq(22)
    d.skip_provision.should be_false
    d.domain.should eq("")
    d.registry_username.should eq("nirlevi")
  end

  it "expands ~ in the key path against $HOME" do
    d = VoIPAppz::DeployDestination.from_yaml("host: 1.2.3.4\nkey: ~/.ssh/k")
    d.key_path.should_not contain("~")
  end

  it "path_for builds config/deploy.<dest>.yml under the project dir" do
    VoIPAppz::DeployDestination.path_for("swpbx", "/proj")
      .should eq("/proj/config/deploy.swpbx.yml")
  end

  it "load raises a helpful error when the file is missing" do
    expect_raises(Exception, /Destination file not found/) do
      VoIPAppz::DeployDestination.load("nope-#{Random::Secure.hex(4)}", "/tmp")
    end
  end
end
