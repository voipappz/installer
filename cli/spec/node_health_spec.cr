require "./spec_helper"
require "http/server"
require "../src/helpers/node_health"

# Health comes from the node itself: it probes its own plane on loopback
# (kamailio RPC, dispatcher routability, FreeSWITCH ESL, host CPU/mem/disk) and
# serves the verdict at /health/node, so `health` and `monitor` read that rather
# than racing their own probes against it.
#
# What is asserted here is the READING of it, because every mistake in that is
# silent: a 503 — the one answer worth reading, since it names what is down —
# being mistaken for "no answer", or a node that is simply not up yet being
# indistinguishable from one reporting nothing wrong.
private def with_node(handler : HTTP::Server::Context -> _, &)
  server = HTTP::Server.new { |ctx| handler.call(ctx) }
  port = server.bind_tcp("127.0.0.1", 0).port
  spawn { server.listen }
  20.times do
    begin
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue
      sleep 10.milliseconds
    end
  end

  original = ENV["VA_NODE_PORT"]?
  ENV["VA_NODE_PORT"] = port.to_s
  begin
    yield
  ensure
    server.close
    if value = original
      ENV["VA_NODE_PORT"] = value
    else
      ENV.delete("VA_NODE_PORT")
    end
  end
end

# What node/local_health.cr's `aggregate` produces: a verdict, a count, and the
# keys of whatever is down with the error recorded for each.
private NODE_DOWN_BODY = {
  ok:    false,
  up:    2,
  total: 4,
  down:  ["kamailio_rpc:Connection refused", "freeswitch_esl"],
}.to_json

private NODE_OK_BODY = {ok: true, up: 4, total: 4, down: [] of String}.to_json

describe VoIPAppz::NodeHealth do
  describe ".url" do
    it "reads the port from the environment, defaulting to the node's own" do
      original = ENV["VA_NODE_PORT"]?
      ENV.delete("VA_NODE_PORT")
      VoIPAppz::NodeHealth.url.should eq "http://127.0.0.1:4000/health/node"

      ENV["VA_NODE_PORT"] = "9999"
      VoIPAppz::NodeHealth.url.should eq "http://127.0.0.1:9999/health/node"
    ensure
      if value = original
        ENV["VA_NODE_PORT"] = value
      else
        ENV.delete("VA_NODE_PORT")
      end
    end
  end

  describe ".verdict" do
    it "reads the verdict a healthy node serves" do
      handler = ->(ctx : HTTP::Server::Context) do
        ctx.response.content_type = "application/json"
        ctx.response.print NODE_OK_BODY
      end

      with_node(handler) do
        verdict = VoIPAppz::NodeHealth.verdict.should_not be_nil
        verdict.ok.should be_true
        verdict.total.should eq 4
        verdict.down.should be_empty
      end
    end

    # THE CASE THAT MATTERS. /health/node answers 503 when something in the
    # plane is down — that is the report, not a failure to report. Treating it
    # as unreachable would turn the one answer worth reading into "no data" and
    # send the caller off to its fallback probes.
    it "reads a 503 as the verdict it is, not as silence" do
      handler = ->(ctx : HTTP::Server::Context) do
        ctx.response.status_code = 503
        ctx.response.content_type = "application/json"
        ctx.response.print NODE_DOWN_BODY
      end

      with_node(handler) do
        verdict = VoIPAppz::NodeHealth.verdict.should_not be_nil
        verdict.ok.should be_false
        verdict.up.should eq 2
        verdict.total.should eq 4
        verdict.failing.should eq 2
        verdict.down.size.should eq 2
      end
    end

    # nil, not an exception: a node that is not up is normal on a box
    # mid-deploy, and the callers have something better to do than crash —
    # health falls back to probing directly, monitor says so in the pane.
    it "answers nil when the node is not there" do
      original = ENV["VA_NODE_PORT"]?
      ENV["VA_NODE_PORT"] = "1" # nothing listens here
      VoIPAppz::NodeHealth.verdict.should be_nil
    ensure
      if value = original
        ENV["VA_NODE_PORT"] = value
      else
        ENV.delete("VA_NODE_PORT")
      end
    end

    it "answers nil on a status that is neither a verdict nor an answer" do
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.status_code = 500 }

      with_node(handler) { VoIPAppz::NodeHealth.verdict.should be_nil }
    end

    it "answers nil when the body is not JSON" do
      handler = ->(ctx : HTTP::Server::Context) do
        ctx.response.print "<html>starting up</html>"
      end

      with_node(handler) { VoIPAppz::NodeHealth.verdict.should be_nil }
    end
  end

  describe ".split_down" do
    it "separates the check from the error the node recorded for it" do
      key, error = VoIPAppz::NodeHealth.split_down("kamailio_rpc:Connection refused")
      key.should eq "kamailio_rpc"
      error.should eq "Connection refused"
    end

    it "splits on the FIRST colon — an error is often a URL and carries its own" do
      key, error = VoIPAppz::NodeHealth.split_down("dispatcher:no route to sip:1.2.3.4:5060")
      key.should eq "dispatcher"
      error.should eq "no route to sip:1.2.3.4:5060"
    end

    it "reports no error when the node named a check without one" do
      key, error = VoIPAppz::NodeHealth.split_down("freeswitch_esl")
      key.should eq "freeswitch_esl"
      error.should be_nil
    end
  end

  describe ".parse" do
    it "survives a payload that is not the verdict the node documents" do
      verdict = VoIPAppz::NodeHealth.parse(%({"error":"nope"})).should_not be_nil
      # Not healthy by default: a body that does not say `ok` has not said the
      # node is fine, and a missing field must never render green.
      verdict.ok.should be_false
      verdict.total.should eq 0
    end
  end
end

# The node grew warnings, a per-group board and live counters (2026-08-25).
# An older node sends none of them, and the CLI must read both shapes: the
# node image and the CLI ship separately.
describe VoIPAppz::NodeHealth do
  describe ".parse" do
    it "reads warn, metrics and the board when the node sends them" do
      body = {
        ok: true, up: 14, total: 14, down: [] of String,
        warn:    ["license:trial, expires in 3 day(s)"],
        metrics: {"calls_reserved" => 1, "calls_licensed" => 3, "channels" => 2, "dialogs" => 1, "registrations" => 14, "sofia_profiles" => 2, "sofia_running" => 2},
        checks:  {"sip" => {"sip_kamailio" => true}, "control" => {"control_nats" => false}},
      }.to_json
      v = VoIPAppz::NodeHealth.parse(body).should_not be_nil
      v.warn.should eq ["license:trial, expires in 3 day(s)"]
      v.metrics["channels"].should eq 2
      v.checks["control"]["control_nats"].should be_false
      v.metrics_line.should eq "calls 1/3 · channels 2 · dialogs 1 · registrations 14 · sofia 2/2"
    end

    it "tolerates an older node that sends none of them" do
      v = VoIPAppz::NodeHealth.parse(NODE_OK_BODY).should_not be_nil
      v.warn.should be_empty
      v.metrics.should be_empty
      v.checks.should be_empty
      v.metrics_line.should eq ""
    end

    it "only prints the counters the node could read" do
      v = VoIPAppz::NodeHealth.parse({ok: true, up: 1, total: 1, down: [] of String, metrics: {"calls_reserved" => 0, "registrations" => 5}}.to_json).not_nil!
      v.metrics_line.should eq "calls 0 · registrations 5"
    end
  end

  describe ".body" do
    it "hands back the node's document verbatim on 200 and on 503, nil otherwise" do
      handler = ->(ctx : HTTP::Server::Context) do
        ctx.response.status_code = 503
        ctx.response.print NODE_DOWN_BODY
      end
      with_node(handler) { VoIPAppz::NodeHealth.body.should eq NODE_DOWN_BODY }

      original = ENV["VA_NODE_PORT"]?
      ENV["VA_NODE_PORT"] = "1"
      VoIPAppz::NodeHealth.body.should be_nil
    ensure
      if value = original
        ENV["VA_NODE_PORT"] = value
      else
        ENV.delete("VA_NODE_PORT")
      end
    end
  end
end

describe "VoIPAppz::NodeHealth::Verdict#capture_line" do
  it "prints the collector counters when the node reports them, nothing otherwise" do
    with_hep = VoIPAppz::NodeHealth.parse({ok: true, up: 1, total: 1, down: [] of String,
      metrics: {"hep_packets_received" => 120, "hep_sip_written" => 118, "hep_parse_errors" => 1, "hep_influx_write_errors" => 1}}.to_json).not_nil!
    with_hep.capture_line.should eq "hep rx 120 · written 118 · errs 2"
    VoIPAppz::NodeHealth.parse(NODE_OK_BODY).not_nil!.capture_line.should eq ""
  end
end
