require "file_utils"
require "./spec_helper"
require "../src/helpers/sipp/runner"
require "../src/helpers/sipp/builtin"

# The scenario compiler is a pure function from a YAML manifest to a SIPp XML
# file and a pcap, so all of it is testable with no SIPp, no network and no
# container. That is the point of porting sippy_cup rather than shelling out to
# it: what SIPp is handed can be asserted on here.
private MANIFEST = <<-YAML
  name: Test Scenario
  source: 192.0.2.15
  destination: 192.0.2.200:5060
  to: 1234@example.com
  max_concurrent: 10
  calls_per_second: 5
  number_of_calls: 20
  steps:
    - invite
    - wait_for_answer
    - ack_answer
    - sleep 3
    - send_digits '12#'
    - sleep 1
    - wait_for_hangup
  YAML

# Walks the libpcap container and yields each packet's RTP payload.
private def rtp_payloads(pcap : Bytes) : Array(Bytes)
  payloads = [] of Bytes
  offset = 24 # file header
  while offset < pcap.size
    length = IO::ByteFormat::LittleEndian.decode(UInt32, pcap[offset + 8, 4]).to_i
    frame = pcap[offset + 16, length]
    payloads << frame[14 + 20 + 8, length - 42] # Ethernet + IPv4 + UDP
    offset += 16 + length
  end
  payloads
end

describe VoIPAppz::Sipp::Options do
  it "reads a sippy_cup manifest" do
    options = VoIPAppz::Sipp::Options.from_manifest(MANIFEST)
    options.name.should eq "Test Scenario"
    options.source.should eq "192.0.2.15"
    options.destination.should eq "192.0.2.200:5060"
    options.concurrency.should eq 10
    options.calls_per_second.should eq 5.0
    options.number_of_calls.should eq 20
    # -s and the URI domain come from the two halves of `to`.
    options.to_service.should eq "1234"
    options.to_domain.should eq "example.com"
    options.source_port.should eq 8836
  end

  it "falls back to SIPp's own placeholders when `to` carries no domain" do
    options = VoIPAppz::Sipp::Options.from_manifest("to: 1234\nsteps: [invite]\n")
    options.to_domain.should eq "[remote_ip]"
  end

  it "names the compiled files after the scenario" do
    VoIPAppz::Sipp::Options.from_manifest(MANIFEST).basename.should eq "test_scenario"
  end
end

describe VoIPAppz::Sipp::Scenario do
  it "compiles the manifest without errors" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST)
    scenario.errors.should be_empty
    scenario.valid?.should be_true
  end

  it "builds an INVITE that offers both PCMU and telephone-event" do
    xml = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).to_xml
    xml.should contain %(<scenario name="Test Scenario">)
    xml.should contain "INVITE sip:[service]@example.com:[remote_port] SIP/2.0"
    xml.should contain "a=rtpmap:0 PCMU/8000"
    # The 101 offered here has to match the payload id Media writes, or the
    # far end will not recognise the DTMF we replay.
    xml.should contain "a=rtpmap:101 telephone-event/8000"
    xml.should contain %(<send retrans="500">)
  end

  it "wraps every message in CDATA with the newlines SIPp demands" do
    xml = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).to_xml
    xml.should contain "<![CDATA[\nINVITE"
    xml.should contain "\n]]>"
  end

  it "marks provisional responses optional and the answer required" do
    xml = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).to_xml
    xml.should contain %(<recv response="100" optional="true"/>)
    xml.should contain %(<recv response="180" optional="true"/>)
    xml.should contain %(<recv response="183" optional="true"/>)
    # rrs keeps the Route set for [routes]; rtd is what makes response-time
    # repartition tables mean anything.
    xml.should contain %(<recv response="200" rrs="true" rtd="true">)
  end

  it "sends exactly one ACK for `wait_for_answer` plus `ack_answer`" do
    # sippy_cup's wait_for_answer also ACKs, which double-ACKs (and double-plays
    # the media) on the manifest its own README ships. See DEVIATION in
    # helpers/sipp/scenario.cr.
    xml = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).to_xml
    xml.scan(/ACK \[next_url\] SIP\/2\.0/).size.should eq 1
  end

  it "declares the variables only a hangup branch would assign" do
    xml = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).to_xml
    xml.should contain %(<Reference variables="remote_addr,local_addr,call_addr,dummy,remote_tag"/>)
  end

  it "pauses the scenario for as long as the media takes to play" do
    xml = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).to_xml
    xml.should contain %(<pause milliseconds="3000"/>)
    # 3 digits x 250ms of event x 2 (the event and the gap after it).
    xml.should contain %(<pause milliseconds="1500"/>)
  end

  it "points the media node at the pcap only when there is one to play" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST)
    scenario.to_xml("/tmp/test_scenario.pcap").should contain %(<exec play_pcap_audio="/tmp/test_scenario.pcap"/>)

    silent = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      steps:
        - invite
        - wait_for_answer
        - wait_for_hangup
      YAML
    silent.media_empty?.should be_true
    silent.to_xml("/tmp/unused.pcap").should_not contain "nop"
  end

  it "is repeatable — the same scenario renders the same XML twice" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST)
    scenario.to_xml("/tmp/a.pcap").should eq scenario.to_xml("/tmp/a.pcap")
  end

  it "authenticates a REGISTER when the manifest supplies a password" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      steps:
        - register 'alice@example.com' 'secret'
      YAML
    xml = scenario.to_xml
    xml.should contain "REGISTER sip:example.com SIP/2.0"
    xml.should contain %(<recv response="401" auth="true" optional="false"/>)
    xml.should contain "[authentication username=alice password=secret]"
  end

  it "reports the step number of a step it cannot build" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      steps:
        - invite
        - teleport
        - send_digits '1'
      YAML
    scenario.valid?.should be_false
    scenario.errors.size.should eq 2
    scenario.errors[0].should contain "step 2"
    scenario.errors[0].should contain "unknown step `teleport`"
    # send_digits before any media has started is the other way a manifest goes
    # wrong, and it has to be caught here rather than by an empty pcap.
    scenario.errors[1].should contain "step 3"
    scenario.errors[1].should contain "needs media"
  end

  it "advertises packetization only when the manifest asks for it" do
    VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).to_xml.should_not contain "a=ptime"

    scenario = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      ptime: 20
      maxptime: 30
      steps:
        - invite
        - wait_for_answer
        - wait_for_hangup
      YAML
    xml = scenario.to_xml
    xml.should contain "a=fmtp:101 0-15\na=ptime:20\na=maxptime:30\n"
  end

  it "fails the call when a received message does not carry what it must" do
    # The SDP-offer check: SIPp stands in as the far end and asserts on what it
    # is handed, which is the difference between a CI check and reading a
    # capture by hand.
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      source_port: 5080
      steps:
        - wait_for_call
        - assert_body 'a=ptime:20'
        - assert_header 'WG67-Version:' 'ED137'
        - send_ringing
        - answer
        - wait_for_hangup
      YAML
    scenario.errors.should be_empty
    xml = scenario.to_xml

    # check_it is what turns a non-match into a failed call; without it SIPp
    # notes the mismatch and carries on.
    xml.should contain %(<ereg regexp="a=ptime:20" search_in="body" check_it="true" assign_to="check_1"/>)
    xml.should contain %(<ereg regexp="ED137" search_in="hdr" header="WG67-Version:" check_it="true" assign_to="check_2"/>)
    # Both assertions hang off the one INVITE that was received.
    xml.scan(/<recv request="INVITE"/).size.should eq 1
  end

  it "times two intervals with separate timers" do
    # ED-137 measures two things a single rtd cannot describe: INVITE to
    # ringing, and ringing to answer. SIPp takes start_rtd on a recv as well as
    # a send, so the second timer can begin at a message we did not send.
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      to: 1234@example.com
      destination: 192.0.2.200
      steps:
        - invite
        - start_timer 1
        - receive_ringing
        - stop_timer 1
        - start_timer 2
        - receive_answer
        - stop_timer 2
        - ack_answer
        - hangup
        - response_time_repartition 50 500 50
      YAML
    scenario.errors.should be_empty
    xml = scenario.to_xml
    xml.should contain %(start_rtd="1")
    xml.should contain %(<recv response="180" optional="true" rtd="1" start_rtd="2"/>)
    xml.should contain %(rtd="2")
    # The buckets are where a p99 comes from.
    xml.should contain %(<ResponseTimeRepartition value="50,100,150,200,250,300,350,400,450,500"/>)
  end

  it "refuses a timer with no message to attach to" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest("steps:\n  - start_timer 1\n")
    scenario.errors.first.should contain "no message to time"
  end

  it "can require that something is ABSENT, not just present" do
    # Half of any compliance rule is a prohibition — "omit the CN payload",
    # "offer only A-law". A scenario asserting only what SHOULD be present
    # passes a message that also carries what should not.
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      steps:
        - wait_for_call
        - assert_body 'a=ptime:20'
        - refute_body 'CN/8000'
        - refute_header 'Priority:' 'non-urgent'
        - answer
        - wait_for_hangup
      YAML
    scenario.errors.should be_empty
    xml = scenario.to_xml
    xml.should contain %(<ereg regexp="a=ptime:20" search_in="body" check_it="true" assign_to="check_1"/>)
    # check_it_inverse is the opposite verdict: the call FAILS when it matches.
    xml.should contain %(<ereg regexp="CN/8000" search_in="body" check_it_inverse="true" assign_to="check_2"/>)
    xml.should contain %(search_in="hdr" header="Priority:" check_it_inverse="true")
    xml.should_not contain %(regexp="CN/8000" search_in="body" check_it="true")
  end

  it "names the failing verb when an assertion has nothing to check" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest("steps:\n  - refute_body 'CN/8000'\n")
    scenario.errors.first.should contain "refute_body"
    scenario.errors.first.should contain "nothing to check"
  end

  it "knows a listening scenario has no destination to dial" do
    uas = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      steps:
        - wait_for_call
        - answer
        - wait_for_hangup
      YAML
    uas.uas?.should be_true
    # SIPp is a server here, so it is not an error that the manifest names
    # nowhere to send calls.
    args = VoIPAppz::Sipp::Runner.sipp_args(uas.options, "/tmp/s.xml", require_destination: false)
    args.should eq ["-p", "8836", "-sf", "/tmp/s.xml"]

    VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST).uas?.should be_false
  end

  it "refuses an assertion with nothing to assert against" do
    scenario = VoIPAppz::Sipp::Scenario.from_manifest(<<-YAML)
      steps:
        - assert_body 'a=ptime:20'
      YAML
    scenario.errors.first.should contain "nothing to check"
  end

  it "writes both artifacts to disk" do
    directory = File.join(Dir.tempdir, "sipp-spec-#{Random::Secure.hex(4)}")
    begin
      scenario = VoIPAppz::Sipp::Scenario.from_manifest(MANIFEST)
      scenario_path, pcap_path = scenario.compile!(directory)
      scenario_path.should eq File.join(directory, "test_scenario.xml")
      pcap_path.should eq File.join(directory, "test_scenario.pcap")
      File.read(scenario_path).should contain %(play_pcap_audio="#{pcap_path}")
      File.size(pcap_path.not_nil!).should be > 0
    ensure
      FileUtils.rm_rf directory
    end
  end
end

describe VoIPAppz::Sipp::Builtin do
  # The examples ship INSIDE the binary, so a broken one is not a broken file
  # somebody notices — it is a broken command on a node. Compile every one.
  it "compiles every scenario it carries" do
    VoIPAppz::Sipp::Builtin::SCENARIOS.each do |name, manifest|
      scenario = VoIPAppz::Sipp::Scenario.from_manifest(manifest, default_name: name)
      scenario.errors.should be_empty
      scenario.to_xml.should contain "<scenario name="
    end
  end

  it "gives every scenario a one-line summary for the listing" do
    VoIPAppz::Sipp::Builtin.names.each do |name|
      VoIPAppz::Sipp::Builtin.summary(name).should_not be_empty
    end
  end

  it "carries a listening scenario and dialling ones" do
    listening = VoIPAppz::Sipp::Scenario.from_manifest(
      VoIPAppz::Sipp::Builtin::SCENARIOS["trunk-offer-check"])
    listening.uas?.should be_true

    VoIPAppz::Sipp::Scenario.from_manifest(
      VoIPAppz::Sipp::Builtin::SCENARIOS["call"]).uas?.should be_false
  end
end

describe VoIPAppz::Sipp::Media do
  it "writes a libpcap file SIPp can replay" do
    media = VoIPAppz::Sipp::Media.new
    media.silence 100
    pcap = media.compile(start_time: 1_000_000_i64, ssrc: 0x11223344_u32)

    IO::ByteFormat::LittleEndian.decode(UInt32, pcap[0, 4]).should eq 0xa1b2c3d4_u32
    IO::ByteFormat::LittleEndian.decode(UInt32, pcap[20, 4]).should eq 1_u32 # Ethernet
    # 100ms of 20ms packets, each 14 + 20 + 8 + 12 + 160 bytes plus a 16-byte
    # record header, after the 24-byte file header.
    pcap.size.should eq 24 + 5 * (16 + 214)
  end

  it "packetizes silence as µ-law at 20ms" do
    media = VoIPAppz::Sipp::Media.new
    media.silence 40
    payloads = rtp_payloads(media.compile(start_time: 0_i64, ssrc: 1_u32))

    payloads.size.should eq 2
    first = payloads[0]
    (first[1] & 0x7f).should eq 0 # PCMU
    (first[1] >> 7).should eq 1   # the marker bit opens the talkspurt
    (payloads[1][1] >> 7).should eq 0
    first[12..].all? { |byte| byte == 0xff }.should be_true
    first.size.should eq 12 + 160
    # The timestamp advances one packet's worth of samples.
    IO::ByteFormat::BigEndian.decode(UInt32, payloads[1][4, 4]).should eq 320
  end

  it "sends an RFC 4733 digit as one event with a repeated end packet" do
    media = VoIPAppz::Sipp::Media.new
    media.dtmf "#"
    payloads = rtp_payloads(media.compile(start_time: 0_i64, ssrc: 1_u32))

    # 250ms at 20ms is 12 packets plus one, and the end-of-event goes out three
    # times: losing it leaves the digit held down for the rest of the call.
    payloads.size.should eq 15
    payloads.each { |packet| (packet[1] & 0x7f).should eq 101 }

    # "#" is event 11 in the RFC 4733 table.
    payloads.first[12].should eq 11
    (payloads.first[13] & 0x80).should eq 0    # not the end yet
    (payloads.first[13] & 0x3f).should eq 10   # volume
    IO::ByteFormat::BigEndian.decode(UInt16, payloads.first[14, 2]).should eq 160

    payloads[-3..].each do |packet|
      (packet[13] & 0x80).should eq 0x80
      # Duration stops growing once the event ends; all three carry the total.
      IO::ByteFormat::BigEndian.decode(UInt16, packet[14, 2]).should eq 160 * 13
    end

    # Every packet of one event carries the event's start timestamp.
    payloads.map { |packet| IO::ByteFormat::BigEndian.decode(UInt32, packet[4, 4]) }.uniq.size.should eq 1
    # Sequence numbers stay contiguous across the redundant packets.
    payloads.map { |packet| IO::ByteFormat::BigEndian.decode(UInt16, packet[2, 2]) }.should eq (1_u16..15_u16).to_a
  end

  it "paces the capture off the media clock" do
    media = VoIPAppz::Sipp::Media.new
    media.silence 60
    pcap = media.compile(start_time: 10_i64, ssrc: 1_u32)

    timestamps = [] of Int64
    offset = 24
    while offset < pcap.size
      seconds = IO::ByteFormat::LittleEndian.decode(UInt32, pcap[offset, 4]).to_i64
      micros = IO::ByteFormat::LittleEndian.decode(UInt32, pcap[offset + 4, 4]).to_i64
      timestamps << seconds * 1_000_000 + micros
      offset += 16 + IO::ByteFormat::LittleEndian.decode(UInt32, pcap[offset + 8, 4]).to_i
    end

    # SIPp replays at the rate these say, so 20ms apart is the whole contract.
    timestamps.should eq [10_020_000_i64, 10_040_000_i64, 10_060_000_i64]
  end

  it "refuses a digit that has no RFC 4733 event" do
    expect_raises(VoIPAppz::Sipp::Error, /invalid DTMF digit/) do
      VoIPAppz::Sipp::Media.new.dtmf "Z"
    end
  end
end

describe VoIPAppz::Sipp::Runner do
  it "builds the SIPp command line from the manifest" do
    options = VoIPAppz::Sipp::Options.from_manifest(MANIFEST)
    args = VoIPAppz::Sipp::Runner.sipp_args(options, "/tmp/test_scenario.xml")

    args.should eq [
      "-p", "8836", "-sf", "/tmp/test_scenario.xml",
      "-l", "10", "-m", "20", "-r", "5", "-s", "1234", "-i", "192.0.2.15",
      "192.0.2.200:5060",
    ]
  end

  it "wires up rate escalation and the stats files" do
    options = VoIPAppz::Sipp::Options.from_manifest(<<-YAML)
      destination: 192.0.2.200
      calls_per_second: 1
      calls_per_second_max: 10
      calls_per_second_interval: 30
      stats_file: /tmp/stats.csv
      transport_mode: t1
      options:
        trace_msg:
        timeout: 60
      YAML
    args = VoIPAppz::Sipp::Runner.sipp_args(options, "/tmp/s.xml")

    # -no_rate_quit keeps the run going once the ceiling is reached rather than
    # ending the test there.
    args.should contain "-no_rate_quit"
    args[args.index("-rate_max").not_nil! + 1].should eq "10"
    args[args.index("-rate_increase").not_nil! + 1].should eq "1"
    args[args.index("-rate_interval").not_nil! + 1].should eq "30"
    args[args.index("-stf").not_nil! + 1].should eq "/tmp/stats.csv"
    args[args.index("-fd").not_nil! + 1].should eq "1"
    args[args.index("-t").not_nil! + 1].should eq "t1"
    # A value-less passthrough option stays a bare flag.
    args[args.index("-trace_msg").not_nil! + 1].should eq "-timeout"
    args.last.should eq "192.0.2.200"
  end

  it "tells SIPp not to read a keyboard that is not there" do
    options = VoIPAppz::Sipp::Options.from_manifest(MANIFEST)
    VoIPAppz::Sipp::Runner.sipp_args(options, "/tmp/s.xml").should_not contain "-nostdin"
    # Without it SIPp dies on a signal in CI rather than reporting a result.
    args = VoIPAppz::Sipp::Runner.sipp_args(options, "/tmp/s.xml", interactive: false)
    args.should contain "-nostdin"
    args.last.should eq "192.0.2.200:5060"
  end

  it "refuses to run a manifest with nowhere to send calls" do
    options = VoIPAppz::Sipp::Options.from_manifest("steps: [invite]\n")
    expect_raises(VoIPAppz::Sipp::Error, /destination/) do
      VoIPAppz::Sipp::Runner.sipp_args(options, "/tmp/s.xml")
    end
  end

  it "caches the pinned binary inside the project" do
    VoIPAppz::Sipp::Runner.cache_path("/opt/va").should eq "/opt/va/.cache/sipp"
    # Pinned, and to a release that ships a STATIC sipp built with pcap — an
    # unpinned tool makes a failing load test unreproducible.
    VoIPAppz::Sipp::Runner::SIPP_URL.should contain VoIPAppz::Sipp::Runner::SIPP_VERSION
    VoIPAppz::Sipp::Runner::SIPP_SHA256.size.should eq 64
  end

  it "separates a failed call from a broken run" do
    VoIPAppz::Sipp::Runner.exit_message(0).should be_nil
    VoIPAppz::Sipp::Runner.calls_failed?(1).should be_true
    VoIPAppz::Sipp::Runner.exit_message(1).should eq "at least one call failed"
    VoIPAppz::Sipp::Runner.calls_failed?(99).should be_false
    VoIPAppz::Sipp::Runner.exit_message(99).should eq "SIPp processed no calls at all"
    VoIPAppz::Sipp::Runner.exit_message(254).not_nil!.should contain "bind"
  end
end
