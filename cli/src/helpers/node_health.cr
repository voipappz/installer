require "http/client"
require "json"
require "uri"

module VoIPAppz
  # THE NODE'S OWN VERDICT, asked on loopback.
  #
  # This replaced the Gatus client (2026-08-20). Gatus is not part of a voip
  # node: it is an app-profile service, so on a split deployment it runs on the
  # mothership while this CLI runs beside the SIP plane, and the fetch to
  # 127.0.0.1:8080 could only ever fail. It worked on a combined box by
  # accident, and `voipappz health` announced "GATUS IS DOWN — monitoring is
  # OFFLINE" on every healthy voip-only node.
  #
  # The node already probes its own plane and says so: LocalHealth
  # (node/local_health.cr) checks kamailio's JSON-RPC, dispatcher routability,
  # FreeSWITCH's ESL and host CPU/mem/disk — all on loopback, nothing crossing a
  # machine boundary — and serves the result at /health/node. So health comes
  # from the thing being asked about, one hop, no extra service and no
  # credential to keep in step.
  #
  # ONE PLACE, because `health` and `monitor` both read it: two copies of a URL
  # drift, and the failure is silent — one command reports healthy off a stale
  # port while the other reports nothing at all.
  module NodeHealth
    DEFAULT_PORT = "4000"
    PATH         = "/health/node"

    CONNECT_TIMEOUT = 2.seconds
    READ_TIMEOUT    = 3.seconds

    def self.port : String
      ENV.fetch("VA_NODE_PORT", DEFAULT_PORT)
    end

    def self.url : String
      "http://127.0.0.1:#{port}#{PATH}"
    end

    def self.get : HTTP::Client::Response
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      client.get(uri.request_target)
    end

    alias Metrics = Hash(String, Int32)
    alias Board = Hash(String, Hash(String, Bool))

    # up/total, the keys of whatever is down (each with the error the node
    # recorded for it), the checks that pass with a note (`warn`), the live
    # counters the node read from its plane (`metrics`), and the full board
    # keyed by group. The last three are empty against an older node, and
    # every reader must cope with that: a node image and this CLI ship
    # separately.
    record Verdict,
      ok : Bool,
      up : Int32,
      total : Int32,
      down : Array(String),
      warn : Array(String) = [] of String,
      metrics : Metrics = Metrics.new,
      checks : Board = Board.new do
      def failing : Int32
        total - up
      end

      # One line of counters, in the order an operator reads them:
      # "calls 1/3 · channels 2 · dialogs 1 · registrations 14 · sofia 2/2".
      # Absent counters are absent — the node only reports what it could read.
      def metrics_line : String
        parts = [] of String
        if licensed = metrics["calls_licensed"]?
          parts << "calls #{metrics["calls_reserved"]? || 0}/#{licensed}"
        elsif reserved = metrics["calls_reserved"]?
          parts << "calls #{reserved}"
        end
        parts << "channels #{metrics["channels"]}" if metrics.has_key?("channels")
        parts << "dialogs #{metrics["dialogs"]}" if metrics.has_key?("dialogs")
        parts << "registrations #{metrics["registrations"]}" if metrics.has_key?("registrations")
        if total = metrics["sofia_profiles"]?
          parts << "sofia #{metrics["sofia_running"]? || 0}/#{total}"
        end
        parts.join(" · ")
      end

      # The capture row: what the node's collector has seen since boot.
      def capture_line : String
        return "" unless metrics.has_key?("hep_packets_received")
        errs = (metrics["hep_parse_errors"]? || 0) + (metrics["hep_influx_write_errors"]? || 0)
        "hep rx #{metrics["hep_packets_received"]} · written #{metrics["hep_sip_written"]? || 0} · errs #{errs}"
      end
    end

    # The node's answer, or nil when it did not give one.
    #
    # nil rather than an exception: a node that is not up yet is a normal state
    # for a box mid-deploy, and both callers have something better to do about it
    # than crash — `health` falls back to probing directly, `monitor` says so in
    # the pane and keeps running.
    # The node's document as it served it, for `health --json`; nil when the
    # node did not answer (same rule as `verdict`).
    def self.body : String?
      response = get
      return nil unless response.status_code == 200 || response.status_code == 503
      response.body
    rescue
      nil
    end

    def self.verdict : Verdict?
      response = get
      # 503 IS AN ANSWER, and the important one: the node is saying something in
      # its plane is down and listing it. Treating it as unreachable would turn
      # the one report worth reading into "no data".
      return nil unless response.status_code == 200 || response.status_code == 503
      parse(response.body)
    rescue
      nil
    end

    def self.parse(body : String) : Verdict?
      json = JSON.parse(body)
      Verdict.new(
        ok: json["ok"]?.try(&.as_bool?) || false,
        up: json["up"]?.try(&.as_i?) || 0,
        total: json["total"]?.try(&.as_i?) || 0,
        down: strings(json["down"]?),
        warn: strings(json["warn"]?),
        metrics: ints(json["metrics"]?),
        checks: board(json["checks"]?),
      )
    rescue
      nil
    end

    private def self.strings(v : JSON::Any?) : Array(String)
      (v.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?)
    end

    private def self.ints(v : JSON::Any?) : Metrics
      m = Metrics.new
      v.try(&.as_h?).try(&.each { |k, x| x.as_i?.try { |i| m[k] = i } })
      m
    end

    private def self.board(v : JSON::Any?) : Board
      b = Board.new
      v.try(&.as_h?).try(&.each do |group, checks|
        checks.as_h?.try(&.each { |k, ok| (b[group] ||= {} of String => Bool)[k] = ok.as_bool? || false })
      end)
      b
    end

    # A down entry is "<key>" or "<key>:<error>" — the node joins them with a
    # colon (node/local_health.cr, `aggregate`). Split on the FIRST one only:
    # the error is frequently a URL and carries its own.
    def self.split_down(entry : String) : Tuple(String, String?)
      key, separator, error = entry.partition(':')
      return {key, nil} if separator.empty? || error.strip.empty?
      {key, error.strip}
    end
  end
end
