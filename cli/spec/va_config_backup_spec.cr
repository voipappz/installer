require "./spec_helper"
require "../src/helpers/va_config"
require "file_utils"

describe VoIPAppz::VaConfig do
  describe ".yaml_path" do
    it "uses the mounted VA_PATH inside the production container" do
      previous = ENV["VA_PATH"]?
      ENV["VA_PATH"] = "/tmp/mounted-node.yaml"
      begin
        VoIPAppz::VaConfig.yaml_path("/stack").should eq("/tmp/mounted-node.yaml")
      ensure
        previous ? (ENV["VA_PATH"] = previous) : ENV.delete("VA_PATH")
      end
    end
  end

  describe ".resolve_auto!" do
    it "generates and persists node and interface UUID v4 values without customers" do
      config = VoIPAppz::DeployConfig.new
      node = VoIPAppz::NodeConfig.new
      interface = VoIPAppz::SipInterfaceConfig.new
      config.nodes << node
      config.sip_interfaces << interface

      VoIPAppz::VaConfig.resolve_auto!(config, "10.0.0.10")
      node_uuid = node.uuid
      interface_uuid = interface.uuid.not_nil!

      uuid_v4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      node_uuid.should match(uuid_v4)
      interface_uuid.should match(uuid_v4)
      interface.node_uuid.should eq(node_uuid)
      node.name.should eq("node-#{node_uuid}")
      config.to_yaml.should_not match(/^customers:/m)

      VoIPAppz::VaConfig.resolve_auto!(config, "10.0.0.11")
      node.uuid.should eq(node_uuid)
      node.name.should eq("node-#{node_uuid}")
      interface.uuid.should eq(interface_uuid)
    end
  end

  describe ".prepare_node! and .configure_node_network!" do
    it "builds a persistent switch identity with the fixed port layout and complete addresses" do
      config = VoIPAppz::DeployConfig.new
      node = VoIPAppz::VaConfig.prepare_node!(config, "10.0.0.10", new_roles: ["switch"])
      topology = VoIPAppz::VaConfig.configure_node_network!(
        config,
        "10.0.0.10",
        "203.0.113.10",
        Set{"10.0.0.10"},
        replace_leg_ips: true
      )

      uuid_v4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      node.uuid.should match(uuid_v4)
      node.name.should eq("node-#{node.uuid}")
      node.type.should eq("switch")
      node.roles.should eq(["switch"])
      node.profile["sip_port"].should eq(VoIPAppz::NodeEnv::KAMAILIO_SIP_PORT)
      topology.should eq(:nat)

      interface = config.sip_interfaces.first
      interface.uuid.not_nil!.should match(uuid_v4)
      interface.node_uuid.should eq(node.uuid)
      interface.profile["port_internal"].should eq(VoIPAppz::NodeEnv::SOFIA_INTERNAL_SIP_PORT)
      interface.profile["port_external"].should eq(VoIPAppz::NodeEnv::SOFIA_EXTERNAL_SIP_PORT)
      (["ip_address_internal", "ip_address_external"] + VoIPAppz::Topology::LEG_FIELDS).each do |key|
        VoIPAppz::NetValidation.usable_node_ipv4?(interface.profile[key]).should be_true
      end
      config.to_yaml.should_not match(/^customers:/m)

      uuid = node.uuid
      name = node.name
      VoIPAppz::VaConfig.prepare_node!(config, "10.0.0.11", new_roles: ["app"])
      node.uuid.should eq(uuid)
      node.name.should eq(name)
      node.roles.should eq(["switch"])
    end

    it "pins an existing installer node to the SIP runtime type" do
      config = VoIPAppz::DeployConfig.new
      existing = VoIPAppz::NodeConfig.new
      existing.type = "app"
      existing.roles = ["app"]
      existing.profile = {
        "ip_address_internal" => "10.0.0.10",
        "ip_address_external" => "203.0.113.10",
      }
      config.nodes << existing
      stale_interface = VoIPAppz::SipInterfaceConfig.new
      stale_interface.node_uuid = "stale-node-uuid"
      config.sip_interfaces << stale_interface

      node = VoIPAppz::VaConfig.prepare_runtime_node!(config, "10.0.0.10")

      node.same?(existing).should be_true
      node.type.should eq("switch")
      node.roles.should eq(["app", "switch"])
      config.sip_interfaces.first.node_uuid.should eq(node.uuid)
    end

    it "rejects loopback or unspecified addresses anywhere in the node document" do
      config = VoIPAppz::DeployConfig.new
      VoIPAppz::VaConfig.prepare_node!(config, "10.0.0.10", new_roles: ["switch"])
      VoIPAppz::VaConfig.configure_node_network!(
        config,
        "10.0.0.10",
        "203.0.113.10",
        Set{"10.0.0.10"},
        replace_leg_ips: true
      )

      node = config.nodes.first
      interface = config.sip_interfaces.first
      invalid_fields = [
        {node.profile, "ip_address_internal", "127.0.0.1"},
        {interface.profile, "ip_address_external", "0.0.0.0"},
        {interface.profile, VoIPAppz::Topology::LEG_FIELDS.first, "127.0.0.2"},
      ]
      invalid_fields.each do |profile, key, invalid|
        previous = profile[key]
        profile[key] = invalid
        expect_raises(ArgumentError, /must be a non-loopback IPv4 address/) do
          VoIPAppz::VaConfig.validate_node_addresses!(config)
        end
        profile[key] = previous
      end
    end

    it "rejects an ambiguous multi-node runtime document" do
      config = VoIPAppz::DeployConfig.new
      config.nodes << VoIPAppz::NodeConfig.new
      config.nodes << VoIPAppz::NodeConfig.new

      expect_raises(ArgumentError, /exactly one node/) do
        VoIPAppz::VaConfig.prepare_runtime_node!(config, "10.0.0.10")
      end
    end
  end

  describe ".backup_existing" do
    it "returns nil when the file does not exist" do
      tmp = File.tempname("va-spec", ".yaml")
      VoIPAppz::VaConfig.backup_existing(tmp).should be_nil
      File.exists?(tmp).should be_false
    end

    it "renames the existing file to a timestamped *.bak.<ts> path" do
      tmp = File.tempname("va-spec", ".yaml")
      File.write(tmp, "before:\n  value: 1\n")
      backup = VoIPAppz::VaConfig.backup_existing(tmp)
      begin
        backup.should_not be_nil
        backup.not_nil!.should match(/\.bak\.\d{8}-\d{6}(?:\.\d+)?$/)
        File.exists?(tmp).should be_false            # original moved
        File.exists?(backup.not_nil!).should be_true # backup landed
        File.read(backup.not_nil!).should eq("before:\n  value: 1\n")
      ensure
        File.delete(backup.not_nil!) if backup && File.exists?(backup.not_nil!)
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end

  describe ".write_yaml" do
    it "writes a fresh file with no backup the first time" do
      tmp_dir = File.tempname("va-spec-dir")
      Dir.mkdir_p(File.join(tmp_dir, "config"))
      begin
        config = VoIPAppz::DeployConfig.new
        backup = VoIPAppz::VaConfig.write_yaml(config, tmp_dir)
        backup.should be_nil
        File.exists?(File.join(tmp_dir, "config/va.yaml")).should be_true
      ensure
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it "keeps every prior file when multiple overwrites land in the same second" do
      tmp_dir = File.tempname("va-spec-dir")
      Dir.mkdir_p(File.join(tmp_dir, "config"))
      begin
        config = VoIPAppz::DeployConfig.new
        VoIPAppz::VaConfig.write_yaml(config, tmp_dir)
        first_backup = VoIPAppz::VaConfig.write_yaml(config, tmp_dir)
        second_backup = VoIPAppz::VaConfig.write_yaml(config, tmp_dir)
        first_backup.should_not be_nil
        second_backup.should_not be_nil
        first_backup.should_not eq(second_backup)
        File.exists?(first_backup.not_nil!).should be_true
        File.exists?(second_backup.not_nil!).should be_true
        File.exists?(File.join(tmp_dir, "config/va.yaml")).should be_true
      ensure
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it "removes process-only credentials instead of persisting them" do
      tmp_dir = File.tempname("va-spec-dir")
      Dir.mkdir_p(File.join(tmp_dir, "config"))
      begin
        config = VoIPAppz::DeployConfig.new
        config.env["VA_API_AUTHORIZATION"] = "Basic test-only-value"
        VoIPAppz::VaConfig.write_yaml(config, tmp_dir)

        written = File.read(File.join(tmp_dir, "config/va.yaml"))
        written.should_not contain("VA_API_AUTHORIZATION")
        config.env.has_key?("VA_API_AUTHORIZATION").should be_false
      ensure
        FileUtils.rm_rf(tmp_dir)
      end
    end
  end
end
