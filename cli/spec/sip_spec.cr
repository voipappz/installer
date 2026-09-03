require "./spec_helper"
require "../src/helpers/sip"

# Unit coverage for the SIP client's PURE half — message building, response
# parsing and digest auth. No socket is opened here; the live wire test is the
# `Kamailio OPTIONS` health check and the CI SIP step.
#
# These matter because before this module the only SIP "test" was whether an
# external Go binary exited 0 — and it was skipped entirely when that binary
# was absent, so the SIP plane passed by never being exercised.
describe VoIPAppz::SIP do
  describe ".build_request" do
    it "emits a well-formed request line and mandatory headers" do
      msg = VoIPAppz::SIP.build_request(
        "OPTIONS", "sip:pbx.example.com",
        "sip:cli@pbx.example.com", "sip:ping@pbx.example.com",
        "10.0.0.5", 5060, "call-id-1", 1, "ftag", "z9hG4bKabc")

      msg.should start_with("OPTIONS sip:pbx.example.com SIP/2.0\r\n")
      msg.should contain("Via: SIP/2.0/UDP 10.0.0.5:5060;branch=z9hG4bKabc;rport")
      msg.should contain("From: <sip:cli@pbx.example.com>;tag=ftag")
      msg.should contain("To: <sip:ping@pbx.example.com>")
      msg.should contain("Call-ID: call-id-1")
      msg.should contain("CSeq: 1 OPTIONS")
      # Mandatory even at zero: without it some proxies wait for a body that
      # never arrives, which surfaces as a timeout rather than a rejection.
      msg.should contain("Content-Length: 0")
      msg.should end_with("\r\n\r\n")
    end

    it "includes Contact/Expires/Authorization only when given" do
      bare = VoIPAppz::SIP.build_request("OPTIONS", "sip:a", "sip:b", "sip:c",
        "1.2.3.4", 5060, "cid", 1, "t", "z9hG4bK1")
      bare.should_not contain("Contact:")
      bare.should_not contain("Expires:")
      bare.should_not contain("Authorization:")

      full = VoIPAppz::SIP.build_request("REGISTER", "sip:a", "sip:b", "sip:c",
        "1.2.3.4", 5060, "cid", 2, "t", "z9hG4bK2",
        contact: "sip:u@1.2.3.4:5060", expires: 60, authorization: "Digest x=1")
      full.should contain("Contact: <sip:u@1.2.3.4:5060>")
      full.should contain("Expires: 60")
      full.should contain("Authorization: Digest x=1")
    end

    it "uses the magic cookie in generated branches (RFC 3261 8.1.1.7)" do
      VoIPAppz::SIP.branch.should start_with("z9hG4bK")
    end
  end

  describe ".parse_response" do
    it "parses status, reason and headers case-insensitively" do
      raw = "SIP/2.0 200 OK\r\nVia: SIP/2.0/UDP 1.2.3.4;branch=z9hG4bK1\r\n" \
            "Server: SIP Proxy\r\nContent-Length: 0\r\n\r\n"
      r = VoIPAppz::SIP.parse_response(raw)
      r.status.should eq(200)
      r.reason.should eq("OK")
      r.header?("server").should eq("SIP Proxy")
      r.header?("SERVER").should eq("SIP Proxy")
      r.header?("nope").should be_nil
    end

    it "parses a reason phrase containing spaces and dashes" do
      r = VoIPAppz::SIP.parse_response("SIP/2.0 403 Forbidden - unknown domain\r\n\r\n")
      r.status.should eq(403)
      r.reason.should eq("Forbidden - unknown domain")
    end

    it "rejects anything that is not a SIP response" do
      expect_raises(VoIPAppz::SIP::Error) { VoIPAppz::SIP.parse_response("HTTP/1.1 200 OK\r\n\r\n") }
      expect_raises(VoIPAppz::SIP::Error) { VoIPAppz::SIP.parse_response("") }
    end
  end

  describe ".parse_auth_params" do
    it "reads quoted and bare parameters" do
      p = VoIPAppz::SIP.parse_auth_params(
        %(Digest realm="asterisk", nonce="abc123", qop=auth, algorithm=MD5))
      p["realm"].should eq("asterisk")
      p["nonce"].should eq("abc123")
      p["qop"].should eq("auth")
      p["algorithm"].should eq("MD5")
    end
  end

  describe ".digest_response" do
    # Cross-checked against an independent MD5 implementation:
    #   HA1 = MD5("alice:asterisk:secret")
    #   HA2 = MD5("REGISTER:sip:example.com")
    #   response = MD5("#{HA1}:abc123:#{HA2}")
    it "computes RFC 2617 MD5 digest without qop" do
      VoIPAppz::SIP.digest_response("alice", "secret", "asterisk", "abc123",
        "REGISTER", "sip:example.com")
        .should eq("16e8af07b772881d75baf35148d2309c")
    end

    it "is sensitive to every input" do
      base = VoIPAppz::SIP.digest_response("alice", "secret", "asterisk", "abc123", "REGISTER", "sip:example.com")
      VoIPAppz::SIP.digest_response("bob", "secret", "asterisk", "abc123", "REGISTER", "sip:example.com").should_not eq(base)
      VoIPAppz::SIP.digest_response("alice", "wrong", "asterisk", "abc123", "REGISTER", "sip:example.com").should_not eq(base)
      VoIPAppz::SIP.digest_response("alice", "secret", "other", "abc123", "REGISTER", "sip:example.com").should_not eq(base)
      VoIPAppz::SIP.digest_response("alice", "secret", "asterisk", "different", "REGISTER", "sip:example.com").should_not eq(base)
      VoIPAppz::SIP.digest_response("alice", "secret", "asterisk", "abc123", "INVITE", "sip:example.com").should_not eq(base)
    end

    it "produces a different digest with qop=auth" do
      plain = VoIPAppz::SIP.digest_response("alice", "secret", "r", "n", "REGISTER", "sip:x")
      qop = VoIPAppz::SIP.digest_response("alice", "secret", "r", "n", "REGISTER", "sip:x",
        qop: "auth", nc: "00000001", cnonce: "deadbeef")
      qop.should_not eq(plain)
    end
  end

  describe ".authorization_header" do
    it "carries the fields a registrar needs" do
      params = VoIPAppz::SIP.parse_auth_params(%(Digest realm="asterisk", nonce="abc123"))
      h = VoIPAppz::SIP.authorization_header("alice", "secret", "sip:example.com", "REGISTER", params)
      h.should start_with("Digest ")
      h.should contain(%(username="alice"))
      h.should contain(%(realm="asterisk"))
      h.should contain(%(nonce="abc123"))
      h.should contain(%(uri="sip:example.com"))
      h.should contain(%(response="16e8af07b772881d75baf35148d2309c"))
      h.should_not contain("qop=")
    end

    it "adds qop/nc/cnonce when the server offers qop" do
      params = VoIPAppz::SIP.parse_auth_params(%(Digest realm="r", nonce="n", qop="auth,auth-int"))
      h = VoIPAppz::SIP.authorization_header("alice", "secret", "sip:x", "REGISTER", params,
        cnonce: "deadbeef")
      h.should contain("qop=auth")
      h.should contain("nc=00000001")
      h.should contain(%(cnonce="deadbeef"))
    end

    it "never sends the password" do
      params = VoIPAppz::SIP.parse_auth_params(%(Digest realm="r", nonce="n"))
      VoIPAppz::SIP.authorization_header("alice", "hunter2", "sip:x", "REGISTER", params)
        .should_not contain("hunter2")
    end
  end
end

# A full INVITE dialog: INVITE -> (100/180) -> 200 -> ACK -> BYE.
#
# `invite` alone only proves a proxy ACCEPTED a request. It says nothing about
# whether the proxy can relay a DIALOG, and that is where a forwarder's bugs
# live: whether the ACK follows the Route set, whether the BYE reaches the far
# side, whether the Contact rewriting survives. Those are the paths
# record_route() exists for.
describe "VoIPAppz::SIP dialog" do
  describe ".build_request with a To-tag" do
    # The tag is a HEADER parameter, not part of the URI (RFC 3261 8.1.1.2).
    # Splicing it inside the angle brackets yields `<sip:a@b>;tag=x>`, which a
    # UAS rejects — and the request silently never joins the dialog.
    it "puts the tag outside the angle brackets" do
      msg = VoIPAppz::SIP.build_request("BYE", "sip:100@pbx", "sip:me@pbx",
        "sip:100@pbx", "10.0.0.1", 5060, "cid", 2, "ftag", "z9hG4bK1",
        to_tag: "remote99")
      msg.should contain "To: <sip:100@pbx>;tag=remote99"
      msg.should_not contain ";tag=remote99>"
    end

    it "omits the tag entirely for an out-of-dialog request" do
      msg = VoIPAppz::SIP.build_request("INVITE", "sip:100@pbx", "sip:me@pbx",
        "sip:100@pbx", "10.0.0.1", 5060, "cid", 1, "ftag", "z9hG4bK1")
      msg.should contain "To: <sip:100@pbx>\r\n"
    end
  end

  describe ".build_request with a body" do
    it "sets Content-Type and a Content-Length that matches the bytes" do
      body = VoIPAppz::SIP.sdp_offer("10.0.0.1")
      msg = VoIPAppz::SIP.build_request("INVITE", "sip:100@pbx", "sip:me@pbx",
        "sip:100@pbx", "10.0.0.1", 5060, "cid", 1, "ftag", "z9hG4bK1", body: body)
      msg.should contain "Content-Type: application/sdp"
      msg.should contain "Content-Length: #{body.bytesize}"
      msg.split("\r\n\r\n", 2)[1].should eq body
    end

    it "still says Content-Length: 0 with no body" do
      msg = VoIPAppz::SIP.build_request("ACK", "sip:100@pbx", "sip:me@pbx",
        "sip:100@pbx", "10.0.0.1", 5060, "cid", 1, "ftag", "z9hG4bK1")
      msg.should contain "Content-Length: 0"
    end

    # Signalling only — nothing binds the port and no RTP is ever sent. The
    # offer exists so the proxy and whatever is downstream have something real
    # to act on.
    it "offers a codec set a PBX will actually accept" do
      sdp = VoIPAppz::SIP.sdp_offer("10.0.0.1", 41000)
      sdp.should contain "m=audio 41000 RTP/AVP 0 8 101"
      sdp.should contain "c=IN IP4 10.0.0.1"
      sdp.should contain "a=sendrecv"
    end
  end

  describe ".build_request with a route set" do
    # In-dialog requests carry the Record-Route set REVERSED (RFC 3261
    # 12.2.1.1). Order is the whole point: reversed wrong, the request walks
    # the proxy chain backwards.
    it "emits one Route header per hop, in the order given" do
      msg = VoIPAppz::SIP.build_request("BYE", "sip:100@pbx", "sip:me@pbx",
        "sip:100@pbx", "10.0.0.1", 5060, "cid", 2, "ftag", "z9hG4bK1",
        routes: ["sip:p2;lr", "sip:p1;lr"])
      msg.index("Route: <sip:p2;lr>").not_nil!
        .should be < msg.index("Route: <sip:p1;lr>").not_nil!
    end
  end

  describe ".parse_response" do
    # Record-Route legitimately appears many times AND several can share one
    # line. Collapsing them into a single last-wins header would silently lose
    # the path, and the ACK would go nowhere.
    it "keeps every Record-Route, across repeated and comma-joined headers" do
      raw = "SIP/2.0 200 OK\r\n" \
            "Record-Route: <sip:p1;lr>, <sip:p2;lr>\r\n" \
            "Record-Route: <sip:p3;lr>\r\n" \
            "To: <sip:100@pbx>;tag=abc\r\n" \
            "Contact: <sip:100@10.0.0.9:5060>\r\n" \
            "Content-Length: 0\r\n\r\n"
      r = VoIPAppz::SIP.parse_response(raw)
      r.record_routes.size.should eq 3
      VoIPAppz::SIP.uri_of(r.record_routes.first).should eq "sip:p1;lr"
    end

    it "extracts the To-tag that makes a dialog confirmed" do
      raw = "SIP/2.0 200 OK\r\nTo: <sip:100@pbx>;tag=xyz789\r\nContent-Length: 0\r\n\r\n"
      VoIPAppz::SIP.to_tag(VoIPAppz::SIP.parse_response(raw)).should eq "xyz789"
    end

    it "has no To-tag on an out-of-dialog response" do
      raw = "SIP/2.0 100 Trying\r\nTo: <sip:100@pbx>\r\nContent-Length: 0\r\n\r\n"
      VoIPAppz::SIP.to_tag(VoIPAppz::SIP.parse_response(raw)).should be_nil
    end

    # The ACK goes to the 2xx's Contact, NOT the original request URI — the
    # proxy may have rewritten it, and that rewrite is the thing worth testing.
    it "unwraps a URI from its angle brackets and display name" do
      VoIPAppz::SIP.uri_of(%(\"Bob\" <sip:bob@x.com>;tag=1)).should eq "sip:bob@x.com"
      VoIPAppz::SIP.uri_of("<sip:p1;lr>").should eq "sip:p1;lr"
      VoIPAppz::SIP.uri_of(nil).should be_nil
    end

    # RFC 3261 §20: when the URI is NOT in angle brackets, semicolon-delimited
    # parameters belong to the HEADER, not the URI. So stripping at the first
    # ";" is correct here — and it is also why a Record-Route carrying `;lr`
    # must be bracketed, since otherwise `lr` is not part of the route at all.
    it "treats bare-URI parameters as header parameters, per RFC 3261 20" do
      VoIPAppz::SIP.uri_of("sip:bare@x.com;tag=1").should eq "sip:bare@x.com"
    end

    it "classifies provisional and success" do
      prov = VoIPAppz::SIP.parse_response("SIP/2.0 180 Ringing\r\nContent-Length: 0\r\n\r\n")
      ok = VoIPAppz::SIP.parse_response("SIP/2.0 200 OK\r\nContent-Length: 0\r\n\r\n")
      no = VoIPAppz::SIP.parse_response("SIP/2.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
      prov.provisional?.should be_true
      ok.success?.should be_true
      no.provisional?.should be_false
      no.success?.should be_false
    end
  end
end
