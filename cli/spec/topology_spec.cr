require "./spec_helper"

# Helper: build a DeployConfig with N empty sip_interfaces.
private def make_config(n_interfaces : Int32 = 1) : VoIPAppz::DeployConfig
  config = VoIPAppz::DeployConfig.new
  n_interfaces.times do |i|
    si = VoIPAppz::SipInterfaceConfig.new
    si.name = "sofia#{i == 0 ? "" : i.to_s}"
    config.sip_interfaces << si
  end
  config
end

describe VoIPAppz::Topology do
  describe ".detect" do
    it "returns :flat when internal == external (single-NIC dev box)" do
      VoIPAppz::Topology.detect("192.168.1.40", "192.168.1.40", Set{"192.168.1.40"})
        .should eq(:flat)
    end

    it "returns :flat regardless of NIC list when IPs match" do
      # Public-NIC short-circuits to :flat when the host has only one IP that
      # is also the public IP — this is the cloud-VM-with-only-public-IP case.
      VoIPAppz::Topology.detect("1.2.3.4", "1.2.3.4", Set{"1.2.3.4"})
        .should eq(:flat)
    end

    it "returns :nat when external IP is not on any NIC (this host's case)" do
      VoIPAppz::Topology.detect("10.11.171.22", "84.110.96.244", Set{"10.11.171.22"})
        .should eq(:nat)
    end

    it "returns :public_nic when external IP is on a NIC alongside a LAN IP" do
      VoIPAppz::Topology.detect("10.0.0.5", "1.2.3.4", Set{"10.0.0.5", "1.2.3.4"})
        .should eq(:public_nic)
    end

    it "returns :nat when local_ips is empty (host can't see its own NICs)" do
      VoIPAppz::Topology.detect("10.0.0.5", "1.2.3.4", Set(String).new)
        .should eq(:nat)
    end
  end

  describe ".derive_leg_ips" do
    it "for :flat sets all eight fields to the same IP" do
      legs = VoIPAppz::Topology.derive_leg_ips("192.168.1.40", "192.168.1.40", :flat)
      legs.size.should eq(8)
      legs.values.uniq.should eq(["192.168.1.40"])
      VoIPAppz::Topology::LEG_FIELDS.each do |key|
        legs.has_key?(key).should be_true
      end
    end

    it "for :nat binds LAN everywhere, advertises public on the carrier leg" do
      legs = VoIPAppz::Topology.derive_leg_ips("10.11.171.22", "84.110.96.244", :nat)
      # All four bind addrs (`internal_*`) are the LAN IP — host has no public NIC.
      legs["ip_address_internal_int_sip"].should eq("10.11.171.22")
      legs["ip_address_internal_ext_sip"].should eq("10.11.171.22")
      legs["ip_address_internal_int_rtp"].should eq("10.11.171.22")
      legs["ip_address_internal_ext_rtp"].should eq("10.11.171.22")
      # LAN-leg advertised IPs stay LAN; carrier-leg advertised IPs are public.
      legs["ip_address_external_int_sip"].should eq("10.11.171.22")
      legs["ip_address_external_int_rtp"].should eq("10.11.171.22")
      legs["ip_address_external_ext_sip"].should eq("84.110.96.244")
      legs["ip_address_external_ext_rtp"].should eq("84.110.96.244")
    end

    it "for :public_nic binds the carrier RTP on the public NIC (so media reaches FS)" do
      legs = VoIPAppz::Topology.derive_leg_ips("10.0.0.5", "1.2.3.4", :public_nic)
      # internal (LAN-phone) profile: bind + advertise the LAN IP
      legs["ip_address_internal_int_sip"].should eq("10.0.0.5") # SIP bind
      legs["ip_address_internal_ext_sip"].should eq("10.0.0.5") # SIP advertised
      legs["ip_address_internal_int_rtp"].should eq("10.0.0.5") # RTP bind
      legs["ip_address_internal_ext_rtp"].should eq("10.0.0.5") # RTP advertised
      # external (carrier) profile: SIP binds LAN (kamailio relay), advertises public
      legs["ip_address_external_int_sip"].should eq("10.0.0.5") # SIP bind
      legs["ip_address_external_ext_sip"].should eq("1.2.3.4")  # SIP advertised
      # RTP BINDS the public NIC (the bug fix — was LAN → silence) and advertises public
      legs["ip_address_external_int_rtp"].should eq("1.2.3.4")  # RTP bind = public
      legs["ip_address_external_ext_rtp"].should eq("1.2.3.4")  # RTP advertised
    end

    # Adaptive to cloud/NAT networks (AWS, GCP, …): the public IP is NOT on any
    # NIC (the provider 1:1-NATs it), so detect() must return :nat and the carrier
    # leg must BIND the LAN IP (where the provider forwards) while ADVERTISING the
    # public IP (where the carrier sends). Real IPs from the swpbx AWS box.
    it "adapts to an AWS NAT box: detect :nat, bind LAN, advertise public" do
      lan = "172.31.30.225" # enX0
      pub = "203.0.113.9"   # NAT'd egress, not on any NIC
      VoIPAppz::Topology.detect(lan, pub, Set{lan}).should eq(:nat)
      legs = VoIPAppz::Topology.derive_leg_ips(lan, pub, :nat)
      legs["ip_address_external_int_rtp"].should eq(lan) # RTP binds LAN (AWS forwards to it)
      legs["ip_address_external_ext_rtp"].should eq(pub) # advertises public (carrier sends here)
      legs["ip_address_external_ext_sip"].should eq(pub) # SIP Contact/Via show the public IP
      legs["ip_address_external_int_sip"].should eq(lan) # SIP binds LAN (kamailio relay)
    end
  end

  describe ".populate!" do
    it "writes all eight fields on an empty sip_interface (NAT case)" do
      config = make_config
      topo = VoIPAppz::Topology.populate!(
        config, "10.11.171.22", "84.110.96.244", Set{"10.11.171.22"}
      )
      topo.should eq(:nat)
      profile = config.sip_interfaces.first.profile
      profile["ip_address_internal_int_sip"].should eq("10.11.171.22")
      profile["ip_address_external_ext_rtp"].should eq("84.110.96.244")
      VoIPAppz::Topology::LEG_FIELDS.each do |key|
        profile.has_key?(key).should be_true
      end
    end

    it "preserves operator overrides — does not overwrite existing values" do
      config = make_config
      config.sip_interfaces.first.profile["ip_address_external_ext_rtp"] = "5.6.7.8"
      VoIPAppz::Topology.populate!(
        config, "10.11.171.22", "84.110.96.244", Set{"10.11.171.22"}
      )
      # Override survives.
      config.sip_interfaces.first.profile["ip_address_external_ext_rtp"].should eq("5.6.7.8")
      # But other fields still get filled in.
      config.sip_interfaces.first.profile["ip_address_internal_int_sip"].should eq("10.11.171.22")
    end

    it "treats empty strings as missing and fills them in" do
      config = make_config
      config.sip_interfaces.first.profile["ip_address_external_ext_sip"] = ""
      VoIPAppz::Topology.populate!(
        config, "10.11.171.22", "84.110.96.244", Set{"10.11.171.22"}
      )
      # Empty string was overwritten with the derived value.
      config.sip_interfaces.first.profile["ip_address_external_ext_sip"].should eq("84.110.96.244")
    end

    it "applies to every sip_interface in the config" do
      config = make_config(3)
      VoIPAppz::Topology.populate!(
        config, "192.168.1.40", "192.168.1.40", Set{"192.168.1.40"}
      )
      config.sip_interfaces.size.should eq(3)
      config.sip_interfaces.each do |si|
        VoIPAppz::Topology::LEG_FIELDS.each do |key|
          si.profile[key].should eq("192.168.1.40")
        end
      end
    end

    it "is a no-op (returns topology, writes nothing) when sip_interfaces is empty" do
      config = make_config(0)
      topo = VoIPAppz::Topology.populate!(
        config, "10.0.0.1", "1.2.3.4", Set{"10.0.0.1"}
      )
      topo.should eq(:nat)
      config.sip_interfaces.should be_empty
    end
  end

  describe ".label" do
    it "renders a human-readable label per topology" do
      VoIPAppz::Topology.label(:flat).should contain("flat")
      VoIPAppz::Topology.label(:nat).should contain("NAT")
      VoIPAppz::Topology.label(:public_nic).should contain("public IP on NIC")
    end
  end
end
