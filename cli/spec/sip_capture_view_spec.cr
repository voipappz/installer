require "./spec_helper"
require "../src/helpers/sip_capture_view"

# The sngrep tab of `voipappz monitor`, drawn without a terminal.
#
# The view is deliberately pure — lines in, strings out, `now` a parameter — so
# what is pinned here is exactly what an operator sees: the dialog list, the
# ladder, and the message pane. A capture view that renders an empty list as an
# error, or grows without a bound, is the failure mode this file exists for.
#
# NO_COLOR is not needed: Colors.enabled? is false when STDOUT is not a tty,
# which it never is under `crystal spec`.

private def line(**over)
  base = {
    ts: "2026-08-25T12:03:40.552Z", src: "192.168.1.40:5060", dst: "172.23.255.10:5070",
    proto: "udp", method: "INVITE", status: "", reason: "", cseq: "1 INVITE",
    call_id: "7f3a-call@1001", from: "1001@ci.local", to: "1004@ci.local",
    ruri: "sip:1004@ci.local", raw: "INVITE sip:1004@ci.local SIP/2.0\r\n",
  }
  VoIPAppz::NodeCapture::Line.parse(base.merge(over).to_json).not_nil!
end

private RAW_INVITE = <<-SIP
INVITE sip:1004@ci.local SIP/2.0\r
Via: SIP/2.0/UDP 192.168.1.40:5060;branch=z9hG4bK7a1b2c3d\r
From: "Alice" <sip:1001@ci.local>;tag=aaa111\r
To: <sip:1004@ci.local>\r
Call-ID: 7f3a-call@1001\r
CSeq: 1 INVITE\r
Max-Forwards: 70\r
User-Agent: voipappz-probe/0.1\r
Content-Type: application/sdp\r
Content-Length: 19\r
\r
v=0\r
o=- 1 1 IN IP4 0\r
SIP

private NOW = Time.parse_rfc3339("2026-08-25T12:03:50.000Z")

describe VoIPAppz::SipCaptureView do
  describe "the dialog list" do
    it "says so, calmly, when nothing is flowing" do
      view = VoIPAppz::SipCaptureView.new
      body = view.frame(80, 20, NOW).join("\n")
      body.should contain "no SIP yet"
      body.should_not contain "error"
      view.dialog_count.should eq 0
    end

    it "reports a broken session as a line, not an exception" do
      view = VoIPAppz::SipCaptureView.new
      view.error = "no broker: pass --url"
      view.frame(80, 20, NOW).join("\n").should contain "capture is not running: no broker"
    end

    it "carries one row per Call-ID with the first method, parties, last reply, count and age" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line)
      view.add(line(ts: "2026-08-25T12:03:41.020Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060",
        method: "", status: "180", reason: "Ringing"))
      view.add(line(ts: "2026-08-25T12:03:42.500Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060",
        method: "", status: "200", reason: "OK"))
      view.dialog_count.should eq 1
      view.message_count.should eq 3
      row = view.frame(80, 20, NOW).find(&.includes?("1001@ci.local")).not_nil!
      row.should contain "12:03:40"
      row.should contain "INVITE"
      row.should contain "1004@ci.local"
      row.should contain "200 OK"
      row.should contain "9s"
    end

    it "keeps the newest dialog at the bottom, and starts selected on it" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line(call_id: "older@1"))
      view.add(line(call_id: "newer@2"))
      rows = view.frame(80, 20, NOW).select(&.includes?("@"))
      rows.index(&.includes?("older@1")).not_nil!.should be < rows.index(&.includes?("newer@2")).not_nil!
      view.selected_dialog.not_nil!.call_id.should eq "newer@2"
    end

    it "moves the selection with the arrows and with j/k, and stops at the ends" do
      view = VoIPAppz::SipCaptureView.new
      3.times { |i| view.add(line(call_id: "call-#{i}")) }
      view.selected_dialog.not_nil!.call_id.should eq "call-2"
      view.handle_key("up").should be_true
      view.selected_dialog.not_nil!.call_id.should eq "call-1"
      view.handle_key("k")
      view.selected_dialog.not_nil!.call_id.should eq "call-0"
      view.handle_key("k")
      view.selected_dialog.not_nil!.call_id.should eq "call-0"
      view.handle_key("j")
      view.selected_dialog.not_nil!.call_id.should eq "call-1"
    end

    it "keeps the selection on its Call-ID while new dialogs push the rows around" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line(call_id: "a@1"))
      view.add(line(call_id: "b@2"))
      view.handle_key("up")
      view.selected_dialog.not_nil!.call_id.should eq "a@1"
      view.add(line(call_id: "c@3"))
      view.selected_dialog.not_nil!.call_id.should eq "a@1"
    end

    it "asks to be closed on q and on esc, and only then" do
      view = VoIPAppz::SipCaptureView.new
      view.handle_key("r").should be_true
      view.handle_key("q").should be_false
      view.handle_key("esc").should be_false
    end
  end

  describe "bounded memory" do
    it "keeps only the last MAX_DIALOGS Call-IDs" do
      view = VoIPAppz::SipCaptureView.new
      (VoIPAppz::SipCaptureView::MAX_DIALOGS + 10).times { |i| view.add(line(call_id: "call-#{i}")) }
      view.dialog_count.should eq VoIPAppz::SipCaptureView::MAX_DIALOGS
      body = view.frame(120, 400, NOW).join("\n")
      body.should_not contain "call-0 "
      body.should contain "call-#{VoIPAppz::SipCaptureView::MAX_DIALOGS + 9}"
    end

    it "stops one dialog growing, and admits what it dropped" do
      view = VoIPAppz::SipCaptureView.new
      (VoIPAppz::SipCaptureView::MAX_MESSAGES + 5).times { view.add(line) }
      dialog = view.selected_dialog.not_nil!
      dialog.messages.size.should eq VoIPAppz::SipCaptureView::MAX_MESSAGES
      dialog.dropped.should eq 5
      view.handle_key("\r")
      view.frame(120, 30, NOW).join("\n").should contain "5 older dropped"
    end
  end

  describe "the ladder" do
    it "draws a column per endpoint and an arrow per message, with time and delta" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line)
      view.add(line(ts: "2026-08-25T12:03:41.020Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060",
        method: "", status: "180", reason: "Ringing"))
      view.handle_key("\r")
      view.mode.should eq VoIPAppz::SipCaptureView::Mode::Flow
      body = view.frame(120, 30, NOW)
      text = body.join("\n")
      text.should contain "192.168.1.40:5060"
      text.should contain "172.23.255.10:5070"
      invite = body.find { |l| l.includes?("INVITE") && l.includes?("▶") }.not_nil!
      invite.should contain "12:03:40.552"
      ringing = body.find { |l| l.includes?("180 Ringing") }.not_nil!
      ringing.should contain "◀"
      ringing.should contain "+0.468"
    end

    # Colour cannot be asserted here: Colors.enabled? is false whenever STDOUT
    # is not a terminal, and under `crystal spec` it never is. What IS pinned
    # is the input to the colour decision — request vs reply, and the response
    # class — because that is the part a change could get wrong silently.
    it "labels a request by its method and a reply by its code and reason" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line)
      view.add(line(ts: "2026-08-25T12:03:41.020Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060",
        method: "", status: "200", reason: "OK"))
      view.add(line(ts: "2026-08-25T12:03:42.020Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060",
        method: "", status: "486", reason: "Busy Here"))
      dialog = view.selected_dialog.not_nil!
      dialog.messages[0].line.request?.should be_true
      dialog.messages[0].line.label.should eq "INVITE"
      dialog.messages[1].line.request?.should be_false
      dialog.last_response.should eq "486 Busy Here"
      view.handle_key("\r")
      text = view.frame(120, 30, NOW).join("\n")
      text.should contain "INVITE"
      text.should contain "200 OK"
      text.should contain "486 Busy Here"
    end

    it "returns to the list on enter and on esc" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line)
      view.handle_key("\r")
      view.mode.should eq VoIPAppz::SipCaptureView::Mode::Flow
      view.handle_key("\r")
      view.mode.should eq VoIPAppz::SipCaptureView::Mode::List
      view.handle_key("\r")
      view.handle_key("esc")
      view.mode.should eq VoIPAppz::SipCaptureView::Mode::List
    end

    it "degrades to text rather than lying when more endpoints than fit appear" do
      view = VoIPAppz::SipCaptureView.new
      # Six legs at 80 columns: three columns fit, the rest are named.
      6.times do |i|
        view.add(line(src: "10.0.0.#{i}:506#{i}", dst: "10.0.0.#{i + 1}:506#{i + 1}",
          ts: "2026-08-25T12:03:4#{i}.000Z"))
      end
      view.handle_key("\r")
      body = view.frame(80, 40, NOW).join("\n")
      body.should contain "more endpoint(s) off screen"
      # Every message is still on screen, drawn or written out.
      body.should contain "10.0.0.5:5065 → 10.0.0.6:5066"
      view.frame(80, 40, NOW).each { |l| VoIPAppz::SipCaptureView.visible_length(l).should be <= 80 }
    end

    it "never draws wider than the terminal, at 80 columns, in either mode" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line)
      view.add(line(ts: "2026-08-25T12:03:41.020Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060",
        method: "", status: "180", reason: "Ringing", raw: RAW_INVITE))
      view.frame(80, 24, NOW).each { |l| VoIPAppz::SipCaptureView.visible_length(l).should be <= 80 }
      view.handle_key("\r")
      view.frame(80, 24, NOW).each { |l| VoIPAppz::SipCaptureView.visible_length(l).should be <= 80 }
    end
  end

  describe "the message pane" do
    it "shows the selected message's headers and its body" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line(raw: RAW_INVITE))
      view.handle_key("\r")
      body = view.frame(140, 30, NOW).join("\n")
      body.should contain "INVITE sip:1004@ci.local SIP/2.0"
      %w[Via From To CSeq Call-ID Max-Forwards Content-Length User-Agent].each do |header|
        body.should contain "#{header}:"
      end
      body.should contain "SIP/2.0/UDP 192.168.1.40:5060"
      body.should contain "body ("
      body.should contain "v=0"
    end

    it "follows the ladder selection" do
      view = VoIPAppz::SipCaptureView.new
      view.add(line(raw: RAW_INVITE))
      view.add(line(ts: "2026-08-25T12:03:41.020Z", src: "172.23.255.10:5070", dst: "192.168.1.40:5060",
        method: "", status: "180", reason: "Ringing", raw: "SIP/2.0 180 Ringing\r\nCall-ID: 7f3a-call@1001\r\n\r\n"))
      view.handle_key("\r")
      view.selected_message.not_nil!.line.status.should eq "180"
      view.frame(140, 30, NOW).join("\n").should contain "SIP/2.0 180 Ringing"
      view.handle_key("up")
      view.selected_message.not_nil!.line.method.should eq "INVITE"
      view.frame(140, 30, NOW).join("\n").should contain "INVITE sip:1004@ci.local"
    end
  end

  describe ".parse_message" do
    it "reads the start line, the headers in wire order, and the body" do
      start_line, pairs, body = VoIPAppz::SipCaptureView.parse_message(RAW_INVITE)
      start_line.should eq "INVITE sip:1004@ci.local SIP/2.0"
      pairs.map(&.[0]).first(3).should eq %w[Via From To]
      pairs.find { |p| p[0] == "CSeq" }.not_nil![1].should eq "1 INVITE"
      body.should contain "v=0"
    end

    it "expands SIP's compact header forms" do
      raw = "SIP/2.0 200 OK\r\nv: SIP/2.0/UDP 10.0.0.1\r\ni: abc@1\r\nl: 0\r\n\r\n"
      pairs = VoIPAppz::SipCaptureView.parse_message(raw)[1]
      pairs.map(&.[0]).should eq %w[Via Call-ID Content-Length]
    end

    it "joins a folded header rather than losing half of it" do
      raw = "REGISTER sip:ci.local SIP/2.0\r\nVia: SIP/2.0/UDP 10.0.0.1\r\n ;branch=z9hG4bKfold\r\n\r\n"
      VoIPAppz::SipCaptureView.parse_message(raw)[1][0][1].should eq "SIP/2.0/UDP 10.0.0.1 ;branch=z9hG4bKfold"
    end

    it "is empty, not an exception, on a message it cannot read" do
      VoIPAppz::SipCaptureView.parse_message("")[1].should be_empty
      VoIPAppz::SipCaptureView.parse_message("garbage")[0].should eq "garbage"
    end
  end

  describe "the small shapes" do
    it "clocks, deltas and ages the way the columns need" do
      VoIPAppz::SipCaptureView.clock("2026-08-25T12:03:40.552Z").should eq "12:03:40.552"
      VoIPAppz::SipCaptureView.clock("nope").should eq "nope"
      VoIPAppz::SipCaptureView.delta(468.milliseconds).should eq "+0.468"
      VoIPAppz::SipCaptureView.delta(125.seconds).should eq "+125.0"
      VoIPAppz::SipCaptureView.age(9.seconds).should eq "9s"
      VoIPAppz::SipCaptureView.age(90.seconds).should eq "1m"
      VoIPAppz::SipCaptureView.age(2.hours).should eq "2h"
    end
  end
end
