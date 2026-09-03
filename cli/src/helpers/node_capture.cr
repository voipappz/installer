require "http/client"
require "json"
require "uri"
require "nats"
require "./nats_control"
require "./node_health"
require "./colors"

module VoIPAppz
  # SIP CAPTURE, as the node exposes it. Two paths that never mix:
  #
  #   control  GET /capture, POST /capture/<action> on loopback — the state of
  #            both halves (kamailio's trace_on, the node's collector) and the
  #            switch for them. Same handler the mothership reaches over NATS
  #            (node:<uuid>:hep.control).
  #   live     node.<uuid>.hep.sip over the broker — one JSON document per SIP
  #            message, published ONLY while a viewer session is open. Session
  #            here means: `stream` with a ttl on hep.control, repeated while
  #            we read, so a closed or crashed viewer never leaves a node
  #            pushing its SIP at the broker for nobody.
  #
  # Long-term history is InfluxDB and a different command (`sbc hep query`);
  # nothing here reads it, and the node keeps nothing for either path.
  module NodeCapture
    PATH            = "/capture"
    CONNECT_TIMEOUT = 2.seconds
    READ_TIMEOUT    = 5.seconds

    STREAM_TTL       = 30
    HEARTBEAT_EVERY  = 10.seconds

    # Where the broker and this node's uuid come from, in order: a flag, the
    # process environment, then the container's own environment directory —
    # /run/s6/container_environment, which the va-env oneshot fills from
    # va.yaml and every service reads. A `docker exec` shell has NONE of it,
    # so without this fallback `tail` in the image could only ever fail.
    S6_ENV_DIR = "/run/s6/container_environment"

    def self.s6_env(name : String) : String
      dir = ENV["VA_S6_ENV_DIR"]? || S6_ENV_DIR
      path = File.join(dir, name)
      File.exists?(path) ? File.read(path).strip : ""
    rescue
      ""
    end

    def self.broker_url(override : String = "") : String
      value = [override, ENV["VA_NATS_URL"]?, ENV["NATS_URL"]?, s6_env("NATS_URL")].compact.find { |v| !v.empty? }
      raise "no broker: pass --url, or set NATS_URL (the node reads it from #{S6_ENV_DIR})" unless value
      value
    end

    def self.node_uuid(override : String = "") : String
      value = [override, ENV["VA_NODE_UUID"]?, ENV["NODE_UUID"]?, s6_env("NODE_UUID"), s6_env("VA_NODE_UUID")].compact.find { |v| !v.empty? }
      raise "no node uuid: pass --node-uuid, or set NODE_UUID (the node reads it from #{S6_ENV_DIR})" unless value
      value
    end

    def self.url(action : String = "") : String
      "http://127.0.0.1:#{NodeHealth.port}#{PATH}#{action.empty? ? "" : "/#{action}"}"
    end

    def self.stream_subject(node_uuid : String) : String
      "node.#{node_uuid}.hep.sip"
    end

    def self.control_subject(node_uuid : String) : String
      "node:#{node_uuid}:hep.control"
    end

    # The node's /capture document, or nil when it did not answer.
    def self.state : JSON::Any?
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      response = client.get(uri.request_target)
      return nil unless response.status_code == 200
      JSON.parse(response.body)
    rescue
      nil
    end

    # enable | disable, through the node. Returns the reply, nil when unreachable.
    def self.control(action : String) : JSON::Any?
      uri = URI.parse(url(action))
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      response = client.post(uri.request_target)
      JSON.parse(response.body)
    rescue
      nil
    end

    # One SIP message off the live subject. Pure: built from the JSON the node
    # publishes, filtered and rendered without a socket, which is what the
    # specs pin.
    record Line,
      ts : String,
      src : String,
      dst : String,
      proto : String,
      method : String,
      status : String,
      reason : String,
      cseq : String,
      call_id : String,
      from : String,
      to : String,
      ruri : String,
      raw : String do
      def self.parse(json : String) : Line?
        j = JSON.parse(json)
        s = ->(k : String) { j[k]?.try(&.as_s?) || "" }
        Line.new(s.call("ts"), s.call("src"), s.call("dst"), s.call("proto"), s.call("method"), s.call("status"),
          s.call("reason"), s.call("cseq"), s.call("call_id"), s.call("from"), s.call("to"), s.call("ruri"), s.call("raw"))
      rescue
        nil
      end

      def request? : Bool
        status.empty?
      end

      # "INVITE" for a request, "200 OK" for a reply — the thing sngrep prints
      # on the arrow.
      def label : String
        request? ? method : "#{status} #{reason}".strip
      end

      # The CSeq method is what a reply belongs to; a request's own method.
      def transaction_method : String
        m = cseq.split(' ').last? || ""
        m.empty? ? method : m
      end

      def matches?(methods : Array(String), call_id_filter : String) : Bool
        return false unless methods.empty? || methods.includes?(transaction_method.upcase)
        return false unless call_id_filter.empty? || call_id.includes?(call_id_filter)
        true
      end

      # The one-line form: time, direction, label, from → to, Call-ID.
      def to_json : String
        {ts: ts, src: src, dst: dst, proto: proto, method: method, status: status, reason: reason, cseq: cseq, call_id: call_id, from: from, to: to, ruri: ruri, raw: raw}.to_json
      end

      def format(color : Bool = true) : String
        time = ts.size >= 23 ? ts[11, 12] : ts
        arrow = "#{src} → #{dst}"
        lbl = label.ljust(14)
        lbl = color ? colorize(lbl) : lbl
        cid = call_id.size > 24 ? call_id[0, 24] : call_id
        "#{time}  #{arrow.ljust(43)}  #{lbl}  #{from} → #{to}  #{color ? Colors.dim(cid) : cid}"
      end

      private def colorize(text : String) : String
        return Colors.cyan(text) if request?
        code = status.to_i? || 0
        return Colors.green(text) if code >= 200 && code < 300
        return Colors.yellow(text) if code < 200 || (code >= 300 && code < 400)
        Colors.red(text)
      end
    end

    # A live session: opens the broker, keeps the node's stream window open
    # with a heartbeat, subscribes, and hands every line to the block. Returns
    # when the block says stop (returns false), the timeout passes, or the
    # process is interrupted. `stream_stop` on the way out closes the window
    # immediately rather than letting it expire.
    class Session
      getter received = 0

      def initialize(@url : String, @node_uuid : String)
        @client = ::NATS::Client.new(URI.parse(@url))
        @stop = Channel(Nil).new(1)
      end

      def heartbeat : Bool
        reply = @client.request(NodeCapture.control_subject(@node_uuid),
          {action: "stream", ttl: STREAM_TTL}.to_json, timeout: 5.seconds)
        !!(reply && JSON.parse(reply.data_string.to_s)["status"]? == "success")
      rescue
        false
      end

      def each(timeout : Time::Span? = nil, & : Line -> Bool)
        raise "the node did not open a capture session on #{NodeCapture.control_subject(@node_uuid)} — is it running, and is capture enabled?" unless heartbeat
        lines = Channel(String).new(1024)
        @client.subscribe(NodeCapture.stream_subject(@node_uuid)) do |msg|
          select
          when lines.send(msg.data_string.to_s)
          else
            # a viewer that cannot keep up sees gaps, the node never waits
          end
        end
        deadline = timeout ? Time.monotonic + timeout : nil
        next_beat = Time.monotonic + HEARTBEAT_EVERY
        loop do
          wait = next_beat - Time.monotonic
          if deadline
            left = deadline - Time.monotonic
            break if left <= Time::Span.zero
            wait = left if left < wait
          end
          wait = 50.milliseconds if wait <= Time::Span.zero
          select
          when raw = lines.receive
            if line = Line.parse(raw)
              @received += 1
              break unless yield line
            end
          when @stop.receive
            break
          when timeout(wait)
            if Time.monotonic >= next_beat
              heartbeat
              next_beat = Time.monotonic + HEARTBEAT_EVERY
            end
          end
        end
      end

      def stop
        @stop.send(nil) rescue nil
      end

      def close
        @client.request(NodeCapture.control_subject(@node_uuid), {action: "stream_stop"}.to_json, timeout: 2.seconds) rescue nil
        @client.close rescue nil
      end
    end
  end
end
