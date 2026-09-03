require "./spec_helper"
require "file_utils"
require "../src/helpers/dispatcher_list"

# The INGRESS kamailio has no database: its destinations are a plain text file
# generated from config/va.yaml. These specs pin the format kamailio's
# dispatcher actually parses, and the two facts that were established against a
# real kamailio 5.6.2 rather than guessed:
#
#   * carrier SOURCES live in set 100 and are matched with ds_is_from_list,
#     which replaced the permissions `address` table (the ingress loads neither
#     db_sqlite nor permissions);
#   * those entries carry flags=4 (DS_DISABLED_DST) so the keepalive prober
#     never OPTIONS-pings a carrier — flags=2 is DS_TRYING_DST, which does not
#     do that.
describe VoIPAppz::DispatcherList do
  config = ->do
    c = VoIPAppz::DeployConfig.new
    n = VoIPAppz::NodeConfig.new
    n.uuid = "node-1"
    n.roles = ["app", "switch"]
    n.profile = {
      "ip_address_internal" => "10.0.0.5",
      "ip_address_external" => "203.0.113.5",
    }
    c.nodes = [n]

    si = VoIPAppz::SipInterfaceConfig.new
    si.name = "sofia"
    si.node_uuid = "node-1"
    si.profile = {"port_internal" => "5060", "port_external" => "5090"}
    si.gateways = [VoIPAppz::GatewayConfig.new(address: "198.51.100.7", tag: "carrier-a")]
    c.sip_interfaces = [si]
    c
  end

  describe ".entries" do
    it "lists FreeSWITCH internal in set 1 and external in set 2" do
      rows = VoIPAppz::DispatcherList.entries(config.call)
      internal = rows.find { |e| e.setid == 1 }.not_nil!
      external = rows.find { |e| e.setid == 2 }.not_nil!
      internal.destination.should eq "sip:10.0.0.5:5060"
      external.destination.should eq "sip:10.0.0.5:5090"
    end

    # This is what replaced the permissions `address` table. The ingress loads
    # neither db_sqlite nor permissions, so a carrier that is not in set 100 is
    # a carrier the ingress cannot recognise.
    it "puts carrier SOURCES in set 100, disabled so they are never probed" do
      rows = VoIPAppz::DispatcherList.entries(config.call)
      carrier = rows.find { |e| e.setid == 100 }.not_nil!
      carrier.destination.should eq "sip:198.51.100.7:0"
      carrier.flags.should eq 4
      carrier.description.should eq "carrier-a"
    end

    it "skips sip_interfaces bound to a different node" do
      c = config.call
      c.sip_interfaces.first.node_uuid = "some-other-node"
      # Only the carrier source survives — it is not node-scoped.
      VoIPAppz::DispatcherList.entries(c).map(&.setid).should eq [100]
    end

    it "is empty when no node has role=switch" do
      c = config.call
      c.nodes.first.roles = ["app"]
      c.sip_interfaces.first.gateways = [] of VoIPAppz::GatewayConfig
      VoIPAppz::DispatcherList.entries(c).should be_empty
    end
  end

  describe ".render" do
    it "emits rows in the dispatcher's own format: setid dest flags prio attrs descr" do
      line = VoIPAppz::DispatcherList.render(config.call)
        .lines.find { |l| l.starts_with?("1 ") }.not_nil!.chomp
      line.should eq %(1 sip:10.0.0.5:5060 0 0 "10.0.0.5" "managed:yaml/sofia/INGRESS")
    end

    it "comments every line that is not a destination" do
      VoIPAppz::DispatcherList.render(config.call).lines.each do |l|
        next if l.strip.empty?
        next if l.starts_with?("#")
        l.should match(/\A\d+ sip:/)
      end
    end

    # An unseeded ingress must be LOUD, not silent: an empty list makes it 404
    # every call, which is distinguishable from a routing bug. The rendered file
    # says so rather than looking like a file that failed to generate.
    it "explains itself when there is nothing to route to" do
      c = config.call
      c.nodes.first.roles = ["app"]
      c.sip_interfaces.first.gateways = [] of VoIPAppz::GatewayConfig
      out = VoIPAppz::DispatcherList.render(c)
      out.should contain "NOTHING CONFIGURED YET"
      out.lines.any? { |l| !l.strip.empty? && !l.starts_with?("#") }.should be_false
    end
  end

  describe ".write" do
    it "writes to the path compose bind-mounts" do
      dir = File.tempname
      Dir.mkdir_p(dir)
      begin
        path = VoIPAppz::DispatcherList.write(config.call, dir)
        path.should eq File.join(dir, "config/kamailio/ingress/dispatcher.list")
        File.read(path).should contain "sip:10.0.0.5:5060"
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end

# `kamcmd dispatcher.list` prints a two-letter FLAGS field and says nothing
# about what it means, so every "D" reads as a fault. For set 100 that is
# backwards — a carrier SOURCE is identified, never dialled, so disabled is the
# correct state — while a routing target going Inactive because FreeSWITCH
# stopped answering keepalives is a real outage that looked identical.
#
#   first letter   A active   I inactive   T trying
#   second letter  X not probed   P probing   D disabled
describe "VoIPAppz::DispatcherList.parse_kamcmd" do
  # Real output, trimmed: kamailio's own nested block text, not JSON.
  output = <<-OUT
    {
    	NRSETS: 3
    	RECORDS: {
    		SET: {
    			ID: 1
    			TARGETS: {
    				DEST: {
    					URI: sip:10.0.0.5:5060
    					FLAGS: AP
    					PRIORITY: 0
    				}
    			}
    		}
    		SET: {
    			ID: 2
    			TARGETS: {
    				DEST: {
    					URI: sip:10.0.0.5:5090
    					FLAGS: IP
    					PRIORITY: 0
    				}
    			}
    		}
    		SET: {
    			ID: 100
    			TARGETS: {
    				DEST: {
    					URI: sip:198.51.100.7:0
    					FLAGS: DX
    					PRIORITY: 0
    				}
    			}
    		}
    	}
    }
    OUT

  targets = VoIPAppz::DispatcherList.parse_kamcmd(output)

  it "reads every destination with its set and flags" do
    targets.size.should eq 3
    targets.map(&.setid).should eq [1, 2, 100]
    targets.map(&.uri).should eq ["sip:10.0.0.5:5060", "sip:10.0.0.5:5090", "sip:198.51.100.7:0"]
  end

  it "calls an active destination up, even while it is being probed" do
    targets[0].state.should eq "up"
    targets[0].usable?.should be_true
    targets[0].note.should be_empty
  end

  # This is the one that matters operationally: nothing routes here.
  it "calls an inactive routing target DOWN and says why" do
    targets[1].state.should eq "DOWN"
    targets[1].usable?.should be_false
    targets[1].note.should contain "OPTIONS keepalives"
  end

  # Set 100 is identification, not routing. Reporting it as broken sends an
  # operator hunting a fault that does not exist.
  it "does not report a carrier source as a fault" do
    carrier = targets[2]
    carrier.source_only?.should be_true
    carrier.disabled?.should be_true
    carrier.state.should eq "source"
    carrier.usable?.should be_true
    carrier.note.should contain "never dialled"
  end

  it "counts only routing targets when deciding whether calls can flow" do
    routable = targets.reject(&.source_only?)
    routable.size.should eq 2
    routable.count(&.usable?).should eq 1
  end

  it "returns nothing for an unseeded dispatcher" do
    VoIPAppz::DispatcherList.parse_kamcmd("{\n\tNRSETS: 0\n}").should be_empty
  end
end

# CAN A CALL ROUTE — the verdict two commands now exit on, so it has to be one
# answer and it has to be right about set 100.
describe "VoIPAppz::DispatcherList.routing" do
  private_target = ->(setid : Int32, flags : String) {
    VoIPAppz::DispatcherList::Target.new(setid, "sip:10.0.0.5:5060", flags)
  }

  it "is Down when every routing target is inactive" do
    # The live case that prompted this: both sofia legs not answering OPTIONS.
    # The command printed "every call will 404" and exited 0.
    targets = [private_target.call(1, "IP"), private_target.call(2, "IP")]
    VoIPAppz::DispatcherList.routing(targets).down?.should be_true
  end

  it "is Down when there is nothing to route to at all" do
    VoIPAppz::DispatcherList.routing([] of VoIPAppz::DispatcherList::Target).down?.should be_true
  end

  it "does NOT count a carrier source as a routing target" do
    # Set 100 is identified, never dialled, and DISABLED is its correct state.
    # Counting it would make a box with one carrier and no switch look routable
    # — the same backwards reading the state decode already fixed once.
    targets = [private_target.call(100, "DX"), private_target.call(1, "IP")]
    VoIPAppz::DispatcherList.routing(targets).down?.should be_true

    only_source = [private_target.call(100, "DX")]
    VoIPAppz::DispatcherList.routing(only_source).down?.should be_true
  end

  it "is Degraded, not Down, while one target still answers" do
    targets = [private_target.call(1, "AP"), private_target.call(2, "IP")]
    VoIPAppz::DispatcherList.routing(targets).degraded?.should be_true
  end

  it "is Ok when every routing target is up, source rows notwithstanding" do
    targets = [private_target.call(100, "DX"), private_target.call(1, "AP")]
    VoIPAppz::DispatcherList.routing(targets).ok?.should be_true
  end
end
