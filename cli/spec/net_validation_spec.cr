require "./spec_helper"
require "../src/helpers/net_validation"

# Unit coverage for the `voipappz sbc egress address` IPv4/CIDR validation. These run
# BEFORE any DB/kamctl write, so they're the gate that keeps bad input out.
describe VoIPAppz::NetValidation do
  describe ".valid_ipv4?" do
    it "accepts canonical dotted-quads" do
      VoIPAppz::NetValidation.valid_ipv4?("10.0.0.1").should be_true
      VoIPAppz::NetValidation.valid_ipv4?("0.0.0.0").should be_true
      VoIPAppz::NetValidation.valid_ipv4?("255.255.255.255").should be_true
      VoIPAppz::NetValidation.valid_ipv4?("198.51.100.10").should be_true
    end

    it "rejects out-of-range octets" do
      VoIPAppz::NetValidation.valid_ipv4?("10.300.0.1").should be_false
      VoIPAppz::NetValidation.valid_ipv4?("256.0.0.1").should be_false
    end

    it "rejects wrong shape" do
      VoIPAppz::NetValidation.valid_ipv4?("1.2.3").should be_false
      VoIPAppz::NetValidation.valid_ipv4?("1.2.3.4.5").should be_false
      VoIPAppz::NetValidation.valid_ipv4?("").should be_false
      VoIPAppz::NetValidation.valid_ipv4?("abc").should be_false
    end

    it "rejects non-canonical octets (leading zeros / garbage)" do
      VoIPAppz::NetValidation.valid_ipv4?("010.0.0.1").should be_false
      VoIPAppz::NetValidation.valid_ipv4?("10.0.0.01").should be_false
      VoIPAppz::NetValidation.valid_ipv4?("10.0.0.x").should be_false
    end
  end

  describe ".parse_cidr" do
    it "uses default_mask for a bare IP" do
      VoIPAppz::NetValidation.parse_cidr("198.51.100.10", 32).should eq({"198.51.100.10", 32})
    end

    it "splits CIDR and the /N wins over default_mask" do
      VoIPAppz::NetValidation.parse_cidr("192.168.0.0/16", 32).should eq({"192.168.0.0", 16})
      VoIPAppz::NetValidation.parse_cidr("10.0.0.0/8", 32).should eq({"10.0.0.0", 8})
    end

    it "accepts boundary masks 0 and 32" do
      VoIPAppz::NetValidation.parse_cidr("10.0.0.0/0", 32).should eq({"10.0.0.0", 0})
      VoIPAppz::NetValidation.parse_cidr("10.0.0.1/32", 8).should eq({"10.0.0.1", 32})
    end

    it "rejects a mask outside 0-32" do
      VoIPAppz::NetValidation.parse_cidr("10.0.0.0/33", 32).should be_nil
      VoIPAppz::NetValidation.parse_cidr("10.0.0.0/-1", 32).should be_nil
    end

    it "rejects a bad IPv4" do
      VoIPAppz::NetValidation.parse_cidr("10.300.0.1", 32).should be_nil
      VoIPAppz::NetValidation.parse_cidr("999.1.2.3/24", 32).should be_nil
    end

    it "rejects a non-numeric mask" do
      VoIPAppz::NetValidation.parse_cidr("10.0.0.0/abc", 32).should be_nil
    end
  end

  describe ".usable_node_ipv4?" do
    it "accepts routable and private interface addresses" do
      VoIPAppz::NetValidation.usable_node_ipv4?("10.0.0.10").should be_true
      VoIPAppz::NetValidation.usable_node_ipv4?("203.0.113.10").should be_true
    end

    it "rejects loopback, unspecified, and malformed addresses" do
      VoIPAppz::NetValidation.usable_node_ipv4?("127.0.0.1").should be_false
      VoIPAppz::NetValidation.usable_node_ipv4?("127.99.1.2").should be_false
      VoIPAppz::NetValidation.usable_node_ipv4?("0.0.0.0").should be_false
      VoIPAppz::NetValidation.usable_node_ipv4?("not-an-ip").should be_false
    end
  end

  # The setup wizard writes these answers into .env, where a bad value only
  # surfaces much later (alerts that never send, a cert that never issues).
  describe ".valid_port?" do
    it "accepts in-range ports" do
      VoIPAppz::NetValidation.valid_port?("587").should be_true
      VoIPAppz::NetValidation.valid_port?("1").should be_true
      VoIPAppz::NetValidation.valid_port?("65535").should be_true
    end

    it "rejects out-of-range, non-numeric and non-canonical" do
      VoIPAppz::NetValidation.valid_port?("0").should be_false
      VoIPAppz::NetValidation.valid_port?("65536").should be_false
      VoIPAppz::NetValidation.valid_port?("-1").should be_false
      VoIPAppz::NetValidation.valid_port?("587 ").should be_false
      VoIPAppz::NetValidation.valid_port?("0587").should be_false
      VoIPAppz::NetValidation.valid_port?("smtp").should be_false
      VoIPAppz::NetValidation.valid_port?("").should be_false
    end
  end

  describe ".common_smtp_port?" do
    it "knows the standard submission ports" do
      %w(25 465 587 2525).each do |p|
        VoIPAppz::NetValidation.common_smtp_port?(p).should be_true
      end
    end

    it "flags anything else for a second look" do
      VoIPAppz::NetValidation.common_smtp_port?("5870").should be_false
      VoIPAppz::NetValidation.common_smtp_port?("80").should be_false
    end
  end

  describe ".valid_email?" do
    it "accepts ordinary addresses" do
      VoIPAppz::NetValidation.valid_email?("admin@example.com").should be_true
      VoIPAppz::NetValidation.valid_email?("ops+alerts@sub.example.co.uk").should be_true
    end

    it "rejects typos" do
      VoIPAppz::NetValidation.valid_email?("admin@").should be_false
      VoIPAppz::NetValidation.valid_email?("@example.com").should be_false
      VoIPAppz::NetValidation.valid_email?("admin at example.com").should be_false
      VoIPAppz::NetValidation.valid_email?("admin@localhost").should be_false
      VoIPAppz::NetValidation.valid_email?("").should be_false
    end
  end

  describe ".valid_hostname?" do
    it "accepts FQDNs and bare labels" do
      VoIPAppz::NetValidation.valid_hostname?("smtp.gmail.com").should be_true
      VoIPAppz::NetValidation.valid_hostname?("pbx20.itd-pbx.com").should be_true
      VoIPAppz::NetValidation.valid_hostname?("localhost").should be_true
    end

    it "rejects malformed labels" do
      VoIPAppz::NetValidation.valid_hostname?("-bad.example.com").should be_false
      VoIPAppz::NetValidation.valid_hostname?("bad-.example.com").should be_false
      VoIPAppz::NetValidation.valid_hostname?("a..b").should be_false
      VoIPAppz::NetValidation.valid_hostname?(".example.com").should be_false
      VoIPAppz::NetValidation.valid_hostname?("exa mple.com").should be_false
      VoIPAppz::NetValidation.valid_hostname?("").should be_false
    end
  end

  describe ".valid_https_url?" do
    it "accepts https webhook URLs" do
      VoIPAppz::NetValidation.valid_https_url?("https://hooks.slack.com/services/T00/B00/xxx").should be_true
      VoIPAppz::NetValidation.valid_https_url?("https://example.com").should be_true
      VoIPAppz::NetValidation.valid_https_url?("https://example.com:8443/hook").should be_true
    end

    it "rejects plain http, missing host and junk" do
      VoIPAppz::NetValidation.valid_https_url?("http://hooks.slack.com/x").should be_false
      VoIPAppz::NetValidation.valid_https_url?("https://").should be_false
      VoIPAppz::NetValidation.valid_https_url?("hooks.slack.com").should be_false
      VoIPAppz::NetValidation.valid_https_url?("").should be_false
    end
  end

  describe ".safe_mothership_transport?" do
    it "requires HTTPS except for literal loopback development endpoints" do
      VoIPAppz::NetValidation.safe_mothership_transport?("https", "cloud.voipappz.io").should be_true
      VoIPAppz::NetValidation.safe_mothership_transport?("http", "localhost").should be_true
      VoIPAppz::NetValidation.safe_mothership_transport?("http", "127.0.0.1").should be_true
      VoIPAppz::NetValidation.safe_mothership_transport?("http", "::1").should be_true

      VoIPAppz::NetValidation.safe_mothership_transport?("http", "api.example.com").should be_false
      VoIPAppz::NetValidation.safe_mothership_transport?("http", "127.attacker.example").should be_false
      VoIPAppz::NetValidation.safe_mothership_transport?(nil, "api.example.com").should be_false
      VoIPAppz::NetValidation.safe_mothership_transport?("https", nil).should be_false
    end
  end
end
