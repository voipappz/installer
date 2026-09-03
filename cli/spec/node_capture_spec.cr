require "./spec_helper"
require "file_utils"
require "../src/helpers/node_capture"

# The live SIP document the node publishes on node.<uuid>.hep.sip, read the
# way `sbc hep tail` reads it. Pure: no broker, no socket — what is pinned is
# the parsing, the filter and the one-line rendering, because a filter that
# silently drops the INVITE you asked for is worse than no filter.
private INVITE = {
  ts: "2026-08-25T12:03:40.552Z", src: "192.168.1.40:5060", dst: "172.23.255.10:5070", proto: "udp",
  method: "INVITE", status: "", reason: "", cseq: "1 INVITE", call_id: "7f3a-call@1001",
  from: "1001@ci.local", to: "1004@ci.local", ruri: "sip:1004@ci.local", raw: "INVITE sip:1004@ci.local SIP/2.0\r\n",
}.to_json

private RINGING = {
  ts: "2026-08-25T12:03:41.020Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060", proto: "udp",
  method: "", status: "180", reason: "Ringing", cseq: "1 INVITE", call_id: "7f3a-call@1001",
  from: "1001@ci.local", to: "1004@ci.local", ruri: "", raw: "SIP/2.0 180 Ringing\r\n",
}.to_json

describe VoIPAppz::NodeCapture do
  it "names the subjects the node uses" do
    VoIPAppz::NodeCapture.stream_subject("abc").should eq "node.abc.hep.sip"
    VoIPAppz::NodeCapture.control_subject("abc").should eq "node:abc:hep.control"
  end

  describe VoIPAppz::NodeCapture::Line do
    it "parses a request and a reply, and labels them like sngrep" do
      inv = VoIPAppz::NodeCapture::Line.parse(INVITE).not_nil!
      inv.request?.should be_true
      inv.label.should eq "INVITE"
      ring = VoIPAppz::NodeCapture::Line.parse(RINGING).not_nil!
      ring.request?.should be_false
      ring.label.should eq "180 Ringing"
      # a reply belongs to its CSeq method — that is what --method filters on
      ring.transaction_method.should eq "INVITE"
    end

    it "filters by transaction method and Call-ID" do
      ring = VoIPAppz::NodeCapture::Line.parse(RINGING).not_nil!
      ring.matches?([] of String, "").should be_true
      ring.matches?(["INVITE"], "").should be_true
      ring.matches?(["REGISTER"], "").should be_false
      ring.matches?([] of String, "7f3a").should be_true
      ring.matches?([] of String, "nope").should be_false
    end

    it "renders one line with time, direction, label, parties and Call-ID" do
      line = VoIPAppz::NodeCapture::Line.parse(INVITE).not_nil!.format(color: false)
      line.should start_with "12:03:40.552"
      line.should contain "192.168.1.40:5060 → 172.23.255.10:5070"
      line.should contain "INVITE"
      line.should contain "1001@ci.local → 1004@ci.local"
      line.should contain "7f3a-call@1001"
    end

    it "round-trips to JSON for --json tails" do
      inv = VoIPAppz::NodeCapture::Line.parse(INVITE).not_nil!
      VoIPAppz::NodeCapture::Line.parse(inv.to_json).not_nil!.call_id.should eq "7f3a-call@1001"
    end

    it "is nil, not an exception, on a document it cannot read" do
      VoIPAppz::NodeCapture::Line.parse("not json").should be_nil
    end
  end
end

# A `docker exec` shell carries none of the node's environment; the services
# read it from /run/s6/container_environment. So must the tail.
describe "VoIPAppz::NodeCapture broker and uuid resolution" do
  it "falls back to the container environment directory, flag and env first" do
    dir = File.tempname("s6env")
    Dir.mkdir(dir)
    File.write(File.join(dir, "NATS_URL"), "nats://from-s6:4222\n")
    File.write(File.join(dir, "NODE_UUID"), "uuid-from-s6\n")
    saved = {"VA_S6_ENV_DIR" => ENV["VA_S6_ENV_DIR"]?, "VA_NATS_URL" => ENV["VA_NATS_URL"]?, "NATS_URL" => ENV["NATS_URL"]?, "VA_NODE_UUID" => ENV["VA_NODE_UUID"]?, "NODE_UUID" => ENV["NODE_UUID"]?}
    ENV["VA_S6_ENV_DIR"] = dir
    %w[VA_NATS_URL NATS_URL VA_NODE_UUID NODE_UUID].each { |k| ENV.delete(k) }
    VoIPAppz::NodeCapture.broker_url.should eq "nats://from-s6:4222"
    VoIPAppz::NodeCapture.node_uuid.should eq "uuid-from-s6"
    ENV["NATS_URL"] = "nats://from-env:4222"
    VoIPAppz::NodeCapture.broker_url.should eq "nats://from-env:4222"
    VoIPAppz::NodeCapture.broker_url("nats://flag:4222").should eq "nats://flag:4222"
  ensure
    saved.not_nil!.each { |k, v| v ? (ENV[k] = v) : ENV.delete(k) }
    FileUtils.rm_rf(dir.not_nil!) if dir
  end

  it "says where to look when nothing is set" do
    saved = {"VA_S6_ENV_DIR" => ENV["VA_S6_ENV_DIR"]?, "VA_NATS_URL" => ENV["VA_NATS_URL"]?, "NATS_URL" => ENV["NATS_URL"]?}
    ENV["VA_S6_ENV_DIR"] = "/nonexistent"
    ENV.delete("VA_NATS_URL"); ENV.delete("NATS_URL")
    expect_raises(Exception, /container_environment/) { VoIPAppz::NodeCapture.broker_url }
  ensure
    saved.not_nil!.each { |k, v| v ? (ENV[k] = v) : ENV.delete(k) }
  end
end
