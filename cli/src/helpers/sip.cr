require "socket"
require "digest/md5"
require "random/secure"

# Minimal SIP client — OPTIONS and REGISTER over UDP.
#
# Written from the specs (RFC 3261 messages, RFC 2617 digest), NOT ported from
# sipexer: sipexer is GPL-3.0, so copying it would force this CLI to GPL-3.0.
# Shelling out to the sipexer BINARY is fine (separate process), and
# `voipappz test` still does that for INVITE/load/stress.
#
# Exists so the health path needs no Go toolchain: `test.cr` used to SKIP its
# SIP checks when the sipexer binary was absent, so the SIP plane could pass by
# never being tested. This cannot skip.
#
# Message building, digest and parsing are pure functions — unit-tested with no
# network (spec/sip_spec.cr). Only `transact` touches I/O.
module VoIPAppz::SIP
  extend self

  # A parsed SIP response — only the parts a health check cares about.
  record Response,
    status : Int32,
    reason : String,
    headers : Hash(String, String),
    record_routes : Array(String) = [] of String do
    def provisional? : Bool
      status < 200
    end

    def success? : Bool
      status >= 200 && status < 300
    end

    def header?(name : String) : String?
      headers[name.downcase]?
    end
  end

  class Error < Exception; end

  # Where kamailio actually listens. kamailio.cfg binds
  # `listen=udp:VA_INTERNAL_IP_ADDRESS_STR:VA_PORT`, and setup writes that as
  # VA_APP_INTERNAL_IP_ADDRESS — the auto-detected NIC address. On a CI runner
  # or any LAN host that is NOT loopback, so a probe hardcoded to 127.0.0.1
  # finds nothing and reports a timeout against a perfectly healthy proxy.
  # That is exactly why the CI SIP step had been failing (with sipexer too,
  # before this module existed). The CLI auto-loads .env, so these are set.
  def default_host : String
    v = ENV["VA_APP_INTERNAL_IP_ADDRESS"]?
    v && !v.strip.empty? ? v.strip : "127.0.0.1"
  end

  def default_port : Int32
    (ENV["VA_SIP_PORT"]? || "5060").to_i? || 5060
  end

  # ─── pure: identifiers ────────────────────────────────────────────────
  # RFC 3261 §8.1.1.7: a branch parameter MUST start with the magic cookie
  # z9hG4bK so downstream elements know the transaction ID is RFC-compliant.
  def branch : String
    "z9hG4bK#{Random::Secure.hex(8)}"
  end

  def tag : String
    Random::Secure.hex(6)
  end

  def call_id(host : String) : String
    "#{Random::Secure.hex(12)}@#{host}"
  end

  # ─── pure: message building ───────────────────────────────────────────
  # Header order follows the RFC examples. Content-Length is mandatory even
  # when zero — omitting it makes some proxies wait for a body that never
  # arrives, which reads as a timeout rather than a rejection.
  def build_request(
    method : String,
    request_uri : String,
    from_uri : String,
    to_uri : String,
    local_host : String,
    local_port : Int32,
    call_id : String,
    cseq : Int32,
    from_tag : String,
    branch : String,
    to_tag : String? = nil,
    transport : String = "UDP",
    contact : String? = nil,
    expires : Int32? = nil,
    authorization : String? = nil,
    proxy_authorization : String? = nil,
    routes : Array(String) = [] of String,
    extra_headers : Array(String) = [] of String,
    body : String? = nil,
    content_type : String = "application/sdp",
    user_agent : String = "voipappz-cli",
  ) : String
    lines = [
      "#{method} #{request_uri} SIP/2.0",
      "Via: SIP/2.0/#{transport.upcase} #{local_host}:#{local_port};branch=#{branch};rport",
      "Max-Forwards: 70",
      "From: <#{from_uri}>;tag=#{from_tag}",
      # The To-tag sits OUTSIDE the angle brackets — it is a header parameter,
      # not part of the URI (RFC 3261 8.1.1.2). Splicing it into the URI string
      # produces `<sip:a@b>;tag=x>`, which a UAS rejects.
      to_tag ? "To: <#{to_uri}>;tag=#{to_tag}" : "To: <#{to_uri}>",
      "Call-ID: #{call_id}",
      "CSeq: #{cseq} #{method}",
      "User-Agent: #{user_agent}",
    ]
    lines << "Contact: <#{contact}>" if contact
    lines << "Expires: #{expires}" if expires
    lines << "Authorization: #{authorization}" if authorization
    lines << "Proxy-Authorization: #{proxy_authorization}" if proxy_authorization
    # Route headers go out in the order given. For an in-dialog request that is
    # the Record-Route set REVERSED (RFC 3261 12.2.1.1) — get it backwards and
    # the request walks the proxy chain the wrong way.
    routes.each { |r| lines << "Route: <#{r}>" }
    extra_headers.each { |h| lines << h }

    if body && !body.empty?
      lines << "Content-Type: #{content_type}"
      lines << "Content-Length: #{body.bytesize}"
      lines.join("\r\n") + "\r\n\r\n" + body
    else
      lines << "Content-Length: 0"
      lines.join("\r\n") + "\r\n\r\n"
    end
  end

  # ─── pure: response parsing ───────────────────────────────────────────
  # Header names are lower-cased on the way in: SIP header names are
  # case-insensitive, and proxies disagree about capitalisation.
  def parse_response(raw : String) : Response
    head = raw.split("\r\n\r\n", 2).first
    lines = head.split("\r\n").reject(&.empty?)
    raise Error.new("empty response") if lines.empty?

    status_line = lines.first
    m = status_line.match(/\ASIP\/2\.0\s+(\d{3})\s*(.*)\z/)
    raise Error.new("not a SIP response: #{status_line}") unless m
    status = m[1].to_i
    reason = m[2].strip

    headers = {} of String => String
    # Record-Route can legitimately appear MANY times, and the order is the
    # route set — collapsing them into one value would lose the path. Kept as
    # a list; everything else keeps last-wins, which is what a health check
    # wants.
    record_routes = [] of String
    lines[1..].each do |line|
      name, _, value = line.partition(":")
      next if value.empty?
      key = name.strip.downcase
      val = value.strip
      if key == "record-route"
        # One header line may carry several comma-separated routes.
        val.split(",").each { |r| record_routes << r.strip }
      else
        headers[key] = val
      end
    end

    Response.new(status, reason, headers, record_routes)
  end

  # The tag on the To header, which is what turns an early dialog into a
  # confirmed one. Without it an ACK is not addressed to the dialog the far end
  # created, and a well-behaved UAS ignores it.
  def to_tag(response : Response) : String?
    tag_of(response.header?("to"))
  end

  def tag_of(header : String?) : String?
    return nil unless header
    header.match(/;tag=([^;\s>]+)/).try(&.[1])
  end

  # The bare URI inside a header like `"Bob" <sip:bob@example.com>;tag=x`.
  def uri_of(header : String?) : String?
    return nil unless header
    if m = header.match(/<([^>]+)>/)
      m[1]
    else
      header.split(";").first.strip
    end
  end

  # ─── pure: digest auth (RFC 2617) ─────────────────────────────────────
  # Parses the params out of a WWW-Authenticate / Proxy-Authenticate value.
  # Values may be quoted or bare; both forms appear in the wild.
  def parse_auth_params(header_value : String) : Hash(String, String)
    params = {} of String => String
    body = header_value.sub(/^\s*(Digest|digest)\s+/, "")
    body.scan(/([a-zA-Z_][a-zA-Z0-9_-]*)\s*=\s*(?:"([^"]*)"|([^,\s]+))/) do |match|
      params[match[1].downcase] = match[2]? || match[3]? || ""
    end
    params
  end

  # response = MD5( MD5(user:realm:pass) : nonce : MD5(method:uri) )
  # qop=auth adds nc and cnonce to the middle section. Only MD5 is implemented
  # — it is what kamailio's auth_db issues by default.
  def digest_response(
    username : String,
    password : String,
    realm : String,
    nonce : String,
    method : String,
    uri : String,
    qop : String? = nil,
    nc : String = "00000001",
    cnonce : String? = nil,
  ) : String
    ha1 = Digest::MD5.hexdigest("#{username}:#{realm}:#{password}")
    ha2 = Digest::MD5.hexdigest("#{method}:#{uri}")
    if qop && !qop.empty?
      cn = cnonce || Random::Secure.hex(8)
      Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{nc}:#{cn}:#{qop}:#{ha2}")
    else
      Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{ha2}")
    end
  end

  # Builds the Authorization header value for the challenge in `params`.
  def authorization_header(
    username : String,
    password : String,
    uri : String,
    method : String,
    params : Hash(String, String),
    cnonce : String? = nil,
    nc : String = "00000001",
  ) : String
    realm = params["realm"]? || ""
    nonce = params["nonce"]? || ""
    # A server may offer several qop values ("auth,auth-int"); we only do auth.
    qop = params["qop"]?.try { |q| q.split(",").map(&.strip).includes?("auth") ? "auth" : nil }
    cn = cnonce || Random::Secure.hex(8)

    resp = digest_response(username, password, realm, nonce, method, uri,
      qop: qop, nc: nc, cnonce: cn)

    parts = [
      %(username="#{username}"),
      %(realm="#{realm}"),
      %(nonce="#{nonce}"),
      %(uri="#{uri}"),
      %(response="#{resp}"),
      %(algorithm=MD5),
    ]
    if opaque = params["opaque"]?
      parts << %(opaque="#{opaque}")
    end
    if qop
      parts << %(qop=#{qop})
      parts << %(nc=#{nc})
      parts << %(cnonce="#{cn}")
    end
    "Digest " + parts.join(", ")
  end

  # ─── I/O ──────────────────────────────────────────────────────────────
  # One request, one final response. Fine for OPTIONS/REGISTER, which are a
  # single transaction. A call is NOT one transaction — see Dialog below.
  def transact(host : String, port : Int32, message : String,
               timeout : Time::Span = 3.seconds) : Response?
    socket = UDPSocket.new
    begin
      socket.read_timeout = timeout
      socket.connect(host, port)
      socket.send(message)
      buf = Bytes.new(65_535)
      count, _ = socket.receive(buf)
      parse_response(String.new(buf[0, count]))
    rescue IO::Error
      # Covers IO::TimeoutError (silence) AND "Connection refused", which is
      # what an ICMP port-unreachable surfaces as on loopback when nothing is
      # bound. Both mean the same thing to a caller: no SIP answer. Returning
      # nil keeps that a reportable result instead of an unhandled exception.
      nil
    ensure
      socket.close rescue nil
    end
  end

  # A socket that stays open for the life of a dialog.
  #
  # `transact` cannot carry a call: an INVITE draws SEVERAL responses (100, 180,
  # then a final), and the ACK and BYE that follow must leave from the same
  # address the Via and Contact advertised, or the far end sends its replies
  # somewhere nothing is listening. Closing after the first datagram would
  # discard the 200 while reporting the 100.
  class Dialog
    getter local_host : String
    getter local_port : Int32

    # One buffer for the dialog, not one per datagram. A call receives 100, 180,
    # 200 and the BYE response — five 64 KB allocations thrown away per call,
    # and it is the dominant allocation under `--level heavy`. The payload is
    # copied out with String.new below, so nothing aliases it.
    @buf = Bytes.new(65_535)

    def initialize(@host : String, @port : Int32, @local_host : String,
                   local_port : Int32 = 0)
      @socket = UDPSocket.new
      @socket.bind(@local_host, local_port)
      @local_port = @socket.local_address.port
      @socket.connect(@host, @port)
    end

    def send(message : String) : Nil
      @socket.send(message)
    end

    # Next response, or nil on silence.
    def recv(timeout : Time::Span) : Response?
      @socket.read_timeout = timeout
      count, _ = @socket.receive(@buf)
      VoIPAppz::SIP.parse_response(String.new(@buf[0, count]))
    rescue IO::Error
      nil
    end

    # Read until a FINAL response (>= 200), collecting provisionals. A proxy
    # that answers 100 and then dies must not look like success, so running out
    # of time returns what was seen rather than pretending.
    def final_response(timeout : Time::Span) : {Response?, Array(Response)}
      provisional = [] of Response
      deadline = Time.monotonic + timeout
      loop do
        left = deadline - Time.monotonic
        return {nil, provisional} if left <= Time::Span.zero
        response = recv(left)
        return {nil, provisional} unless response
        return {response, provisional} unless response.provisional?
        provisional << response
      end
    end

    def close : Nil
      @socket.close rescue nil
    end
  end

  # ─── a whole call ─────────────────────────────────────────────────────
  #
  # INVITE -> (100/180) -> 200 -> ACK -> [hold] -> BYE.
  #
  # Why this and not `invite` alone: an INVITE that draws a 200 only proves the
  # proxy ACCEPTED the request. It says nothing about whether the proxy can
  # relay a DIALOG, and that is where a forwarder's bugs live — whether ACK
  # follows the Route set, whether the BYE reaches the far side, whether the
  # Contact rewriting survives. Those are exactly the paths `record_route()`
  # exists for, and none of them are exercised by a single request.
  record CallResult,
    final : Response?,
    provisional : Array(Response),
    ack_sent : Bool,
    bye : Response?,
    error : String? = nil do
    def answered? : Bool
      !!final.try(&.success?)
    end

    def ringing? : Bool
      provisional.any? { |r| r.status == 180 || r.status == 183 }
    end
  end

  # A minimal SDP offer. Signalling only: nothing binds this port and no RTP is
  # ever sent — it exists so the proxy and whatever is downstream have a real
  # offer to act on, which is what makes the dialog realistic.
  def sdp_offer(local_host : String, rtp_port : Int32 = 40000) : String
    ["v=0",
     "o=voipappz 0 0 IN IP4 #{local_host}",
     "s=voipappz-cli",
     "c=IN IP4 #{local_host}",
     "t=0 0",
     "m=audio #{rtp_port} RTP/AVP 0 8 101",
     "a=rtpmap:0 PCMU/8000",
     "a=rtpmap:8 PCMA/8000",
     "a=rtpmap:101 telephone-event/8000",
     "a=sendrecv",
     ""].join("\r\n")
  end

  def call(host : String, port : Int32,
           user : String = "100",
           domain : String? = nil,
           username : String? = nil,
           password : String? = nil,
           duration : Time::Span = Time::Span.zero,
           timeout : Time::Span = 5.seconds,
           with_sdp : Bool = true) : CallResult
    dom = domain || host
    lh = local_host(host)
    dialog = Dialog.new(host, port, lh)
    begin
      from_uri = "sip:#{username || "voipappz-cli"}@#{dom}"
      to_uri   = "sip:#{user}@#{dom}"
      cid      = call_id(dom)
      ftag     = tag
      contact  = "sip:#{username || "voipappz-cli"}@#{dialog.local_host}:#{dialog.local_port}"
      cseq     = 1
      body     = with_sdp ? sdp_offer(dialog.local_host) : nil

      invite_branch = branch
      dialog.send(build_request("INVITE", to_uri, from_uri, to_uri,
        dialog.local_host, dialog.local_port, cid, cseq, ftag, invite_branch,
        contact: contact, body: body))

      final, provisional = dialog.final_response(timeout)
      return CallResult.new(nil, provisional, false, nil, "no final response") unless final

      # A challenge is not a failure — answer it and re-INVITE. 407 comes from
      # a PROXY (Proxy-Authenticate/Proxy-Authorization), 401 from a registrar
      # or UAS. A forwarder that challenges uses 407, so a client that only
      # understands 401 fails against exactly the box it is meant to test.
      if (final.status == 401 || final.status == 407) && username && password
        proxy = final.status == 407
        challenge = final.header?(proxy ? "proxy-authenticate" : "www-authenticate")
        if challenge
          # ACK the challenge on the SAME branch: for a non-2xx final the ACK
          # belongs to the original INVITE transaction (RFC 3261 17.1.1.3).
          dialog.send(build_request("ACK", to_uri, from_uri, to_uri,
            dialog.local_host, dialog.local_port,
            cid, cseq, ftag, invite_branch, to_tag: to_tag(final)))

          cseq += 1
          auth = authorization_header(username, password, "INVITE", to_uri,
            parse_auth_params(challenge))
          dialog.send(build_request("INVITE", to_uri, from_uri, to_uri,
            dialog.local_host, dialog.local_port, cid, cseq, ftag, branch,
            contact: contact, body: body,
            authorization: proxy ? nil : auth,
            proxy_authorization: proxy ? auth : nil))
          final, more = dialog.final_response(timeout)
          provisional.concat(more)
          return CallResult.new(nil, provisional, false, nil, "no final response after auth") unless final
        end
      end

      unless final.success?
        # Still ACK a failure final, same branch — otherwise the far end keeps
        # retransmitting it.
        dialog.send(build_request("ACK", to_uri, from_uri, to_uri,
          dialog.local_host, dialog.local_port,
          cid, cseq, ftag, invite_branch, to_tag: to_tag(final)))
        return CallResult.new(final, provisional, true, nil)
      end

      # Confirmed. The remote target is the 2xx's Contact, NOT the original
      # request URI — the proxy may have rewritten it, and that rewrite is the
      # thing worth testing. The route set is Record-Route REVERSED.
      remote_target = uri_of(final.header?("contact")) || to_uri
      routes = final.record_routes.compact_map { |r| uri_of(r) }.reverse
      dtag = to_tag(final)

      dialog.send(build_request("ACK", remote_target, from_uri, to_uri,
        dialog.local_host, dialog.local_port, cid, cseq, ftag, branch,
        to_tag: dtag, routes: routes))

      sleep duration if duration > Time::Span.zero

      cseq += 1
      dialog.send(build_request("BYE", remote_target, from_uri, to_uri,
        dialog.local_host, dialog.local_port, cid, cseq, ftag, branch,
        to_tag: dtag, routes: routes))
      bye, _ = dialog.final_response(timeout)

      CallResult.new(final, provisional, true, bye)
    ensure
      dialog.close
    end
  end

  # ─── high level ───────────────────────────────────────────────────────
  # OPTIONS keepalive. ANY final response proves the stack is alive and
  # parsing SIP — a 404/405 still means something is listening and answering,
  # which is exactly what a liveness check asks. Only silence is a failure.
  def options(host : String, port : Int32,
              domain : String? = nil,
              timeout : Time::Span = 3.seconds) : Response?
    dom = domain || host
    req = build_request(
      "OPTIONS", "sip:#{dom}",
      "sip:voipappz-cli@#{dom}", "sip:ping@#{dom}",
      local_host(host), 5060,
      call_id(dom), 1, tag, branch,
    )
    transact(host, port, req, timeout)
  end

  # INVITE — proves the ROUTING plane, which OPTIONS does not.
  #
  # A forwarder answers OPTIONS locally without ever consulting the dispatcher,
  # so an OPTIONS probe stays green against a box whose routing is completely
  # broken. Only an INVITE exercises the decision the box actually exists to
  # make.
  #
  # Returns the FIRST response, which for a relayed call is the provisional
  # 100 Trying — that is the proof of routing. Chasing the final response would
  # mean tracking a dialog and ACKing it, which is a load-test's job, not a
  # reachability probe's. A 404 here is equally informative: the request was
  # understood and had nowhere to go.
  #
  # No SDP: this must not establish media. It asks "would you route this",
  # not "let us have a call".
  def invite(host : String, port : Int32,
             user : String = "100",
             domain : String? = nil,
             timeout : Time::Span = 3.seconds) : Response?
    dom = domain || host
    lh = local_host(host)
    req = build_request(
      "INVITE", "sip:#{user}@#{dom}",
      "sip:voipappz-cli@#{dom}", "sip:#{user}@#{dom}",
      lh, 5060,
      call_id(dom), 1, tag, branch,
      contact: "sip:voipappz-cli@#{lh}:5060",
    )
    transact(host, port, req, timeout)
  end

  # REGISTER with digest auth. Returns the FINAL response: the 401/407
  # challenge is answered inline, so a 200 here means credentials worked.
  def register(host : String, port : Int32,
               username : String, password : String,
               domain : String? = nil,
               expires : Int32 = 60,
               timeout : Time::Span = 3.seconds) : Response?
    dom = domain || host
    lhost = local_host(host)
    lport = 5060
    uri = "sip:#{dom}"
    aor = "sip:#{username}@#{dom}"
    cid = call_id(dom)
    ftag = tag
    contact = "sip:#{username}@#{lhost}:#{lport}"

    first = transact(host, port, build_request(
      "REGISTER", uri, aor, aor, lhost, lport, cid, 1, ftag, branch,
      contact: contact, expires: expires,
    ), timeout)

    return nil unless first
    return first unless first.status == 401 || first.status == 407

    challenge = first.header?("www-authenticate") || first.header?("proxy-authenticate")
    raise Error.new("#{first.status} without an auth challenge header") unless challenge

    auth = authorization_header(username, password, uri, "REGISTER",
      parse_auth_params(challenge))

    # CSeq MUST increment for the retry (RFC 3261 §22.2) or the proxy treats
    # it as a retransmission and replays the same challenge forever.
    transact(host, port, build_request(
      "REGISTER", uri, aor, aor, lhost, lport, cid, 2, ftag, branch,
      contact: contact, expires: expires, authorization: auth,
    ), timeout)
  end

  # Via/Contact must carry an address the far side could route back to. We do
  # not bind a fixed port, so advertise the source address the kernel would
  # pick for this destination; for loopback targets that is 127.0.0.1.
  private def local_host(target : String) : String
    socket = UDPSocket.new
    socket.connect(target, 9)
    addr = socket.local_address.address
    socket.close
    addr
  rescue
    "127.0.0.1"
  end

end
