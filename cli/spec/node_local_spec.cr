require "./spec_helper"
require "../src/helpers/docker"
require "../src/helpers/node_local"
require "../src/helpers/project"
require "../src/helpers/services"
require "../src/helpers/va_config"
require "file_utils"

# WHAT AN INSTALLED NODE LOOKS LIKE TO THE CLI.
#
# install.sh leaves a directory with config/va.yaml and a 0600 .env in it, and
# nothing else the CLI can resolve through — no docker-compose.yaml, no
# config/services.tsv. Every example here builds exactly that and asserts the
# commands that manage a running node can still find it.
describe VoIPAppz::NodeLocal do
  # A directory shaped like an install, with the compose project deliberately
  # out of reach: VA_PROJECT_DIR is normally the spec fixture, which HAS a
  # catalog, and with it present none of this code path is reached.
  around_each do |example|
    dir = File.tempname("va-node-install")
    Dir.mkdir_p File.join(dir, "config")
    saved_project = ENV["VA_PROJECT_DIR"]?
    saved_install = ENV["INSTALL_DIR"]?
    saved_path = ENV["VA_PATH"]?
    ENV.delete("VA_PATH")
    ENV["INSTALL_DIR"] = dir
    ENV["VA_PROJECT_DIR"] = File.join(dir, "nowhere")
    VoIPAppz::Project.reset!
    VoIPAppz::Services.reset!
    VoIPAppz::NodeLocal.reset!
    begin
      example.run
    ensure
      FileUtils.rm_rf(dir)
      saved_project ? (ENV["VA_PROJECT_DIR"] = saved_project) : ENV.delete("VA_PROJECT_DIR")
      saved_install ? (ENV["INSTALL_DIR"] = saved_install) : ENV.delete("INSTALL_DIR")
      saved_path ? (ENV["VA_PATH"] = saved_path) : ENV.delete("VA_PATH")
      VoIPAppz::Project.reset!
      VoIPAppz::Services.reset!
      VoIPAppz::NodeLocal.reset!
    end
  end

  install = ->(yaml : String) do
    File.write(VoIPAppz::NodeLocal.yaml_path, yaml)
  end
  default_yaml = "nodes:\n  - uuid: n1\n    profile:\n      ip_address_internal: 10.0.0.5\n"

  it "is not installed until its va.yaml is there" do
    VoIPAppz::NodeLocal.installed?.should be_false
    install.call(default_yaml)
    VoIPAppz::NodeLocal.installed?.should be_true
  end

  # .env is 0600 root-owned by design, so an unprivileged operator sees no .env
  # at all. Keying "is a node installed here" off it would answer "no node" on
  # a box that plainly has one.
  it "does not need a readable .env to see the install" do
    install.call(default_yaml)
    VoIPAppz::NodeLocal.env_readable?.should be_false
    VoIPAppz::NodeLocal.installed?.should be_true
    VoIPAppz::NodeLocal.env.empty?.should be_true
  end

  # install.sh reads this file with `sed -n 's/^KEY=//p' | head -1` when it
  # builds the node's `docker run`, so a duplicated key must resolve here to
  # the value the container is actually running with.
  it "reads .env the way the installer does — first wins" do
    install.call(default_yaml)
    File.write(VoIPAppz::NodeLocal.env_path, "VA_VOIP_IMAGE=one\nVA_VOIP_IMAGE=two\n")
    VoIPAppz::NodeLocal.reset!
    VoIPAppz::NodeLocal.env["VA_VOIP_IMAGE"].should eq("one")
  end

  describe "the kamailio commands" do
    # THE CRASH THIS EXISTS TO PREVENT. `Services.find?` reached `.all`, which
    # raises CatalogMissing, so `voipappz sbc egress status` on a node host died
    # with an unhandled exception over fourteen `???` frames.
    it "answers nil for a catalog that is not there instead of raising" do
      install.call(default_yaml)
      VoIPAppz::Services.available?.should be_false
      VoIPAppz::Services.find?("kamailio-egress").should be_nil
    end

    it "resolves the merged roles to the installed node's container" do
      install.call(default_yaml)
      VoIPAppz::Docker.installed_node?.should eq(VoIPAppz::NodeLocal::CONTAINER)
    end

    # A node runs the egress and nothing else — the ingress belongs to the app
    # plane, on another machine. Answering nil is what makes `ingress?(va-voip)`
    # false, so the SQLite-backed commands treat it as the egress.
    it "has no ingress" do
      install.call(default_yaml)
      VoIPAppz::Docker.ingress_container.should be_nil
      VoIPAppz::Docker.ingress?(VoIPAppz::NodeLocal::CONTAINER).should be_false
    end

    it "leaves a host WITH a catalog alone" do
      install.call(default_yaml)
      ENV["VA_PROJECT_DIR"] = File.expand_path("fixtures/project", __DIR__)
      VoIPAppz::Project.reset!
      VoIPAppz::Services.reset!
      VoIPAppz::Services.available?.should be_true
      # On a mothership box /opt/voipappz is that stack, not a node: the catalog
      # is the truth there and this path must not fire.
      VoIPAppz::Docker.installed_node?.should be_nil
    end
  end

  # Every "it is not running" message in the SIP path used to end in
  # `voipappz up -p voip`: a compose command against a project a node does not
  # have. One helper so the advice cannot be right in one message and wrong in
  # the next.
  describe "#start_hint" do
    it "names make up on a node host" do
      install.call(default_yaml)
      VoIPAppz::NodeLocal.start_hint.should_not be_nil
      VoIPAppz::NodeLocal.start_hint.not_nil!.should contain("make up")
      VoIPAppz::NodeLocal.start_hint.not_nil!.should contain(VoIPAppz::NodeLocal.install_dir)
    end

    it "says nothing on a box with no node, so the compose advice still stands" do
      VoIPAppz::NodeLocal.start_hint.should be_nil
    end
  end

  describe "va.yaml resolution" do
    it "finds the installed node's file when there is no project" do
      install.call(default_yaml)
      VoIPAppz::VaConfig.yaml_path(File.join(ENV["INSTALL_DIR"], "nowhere"))
        .should eq(VoIPAppz::NodeLocal.yaml_path)
    end

    # `setup` is told to CREATE a va.yaml at this path, so a checkout that does
    # not have one yet must NOT be redirected to /opt/voipappz — that would
    # write the wrong box's node file.
    it "never redirects a real project that has no va.yaml yet" do
      install.call(default_yaml)
      checkout = File.join(ENV["INSTALL_DIR"], "checkout")
      Dir.mkdir_p checkout
      File.write(File.join(checkout, VoIPAppz::Project::COMPOSE_FILE), "services: {}\n")
      VoIPAppz::VaConfig.yaml_path(checkout)
        .should eq(File.join(checkout, VoIPAppz::VaConfig::VA_YAML))
    end

    it "still lets VA_PATH win" do
      install.call(default_yaml)
      ENV["VA_PATH"] = "/tmp/explicit.yaml"
      VoIPAppz::VaConfig.yaml_path("/anywhere").should eq("/tmp/explicit.yaml")
    end
  end

  # `voipappz test scenario call --to 1001` on a node means the node. The
  # kamailio port, not a Sofia one: kamailio is the front door and 5070/5090 sit
  # behind it.
  describe "#sip_destination" do
    it "is the node's kamailio address from its own va.yaml" do
      install.call(default_yaml)
      VoIPAppz::NodeLocal.sip_destination.should eq("10.0.0.5:5060")
    end

    it "honours an explicit sip_port" do
      install.call("nodes:\n  - uuid: n1\n    profile:\n      ip_address_internal: 10.0.0.5\n      sip_port: '5080'\n")
      VoIPAppz::NodeLocal.sip_destination.should eq("10.0.0.5:5080")
    end

    it "is nil with nothing installed" do
      VoIPAppz::NodeLocal.sip_destination.should be_nil
    end
  end
end
