require "http/client"
require "json"
require "base64"
require "./colors"

module VoIPAppz::InfluxDB
  # Config — mirrors Ruby initializer in web container:
  #   config.host     = 'influxdb'
  #   config.port     = 8181
  #   config.username = 'token'
  #   config.password = Config.va_monitor_token
  #   config.database = 'telegraf'
  # The stack runs its own InfluxDB (compose `influxdb`, published
  # 127.0.0.1:8181, started with --without-auth), so local is the right
  # default. It previously defaulted to a remote production host.
  HOST     = ENV.fetch("VA_INFLUXDB_HOST", "127.0.0.1")
  PORT     = (ENV.fetch("VA_INFLUXDB_PORT", "8181")).to_i
  DATABASE = ENV.fetch("VA_INFLUXDB_DATABASE", "telegraf")
  USERNAME = "token"
  # No default token. The local InfluxDB runs --without-auth, so an empty
  # password is correct here; a remote instance supplies VA_MONITOR_TOKEN.
  # A live apiv3_* token used to sit here as the fallback — committed, and in
  # git history, so it must be ROTATED, not just deleted.
  PASSWORD = ENV.fetch("VA_MONITOR_TOKEN", "")

  struct LogEntry
    getter time : String
    getter appname : String
    getter host : String
    getter severity : String
    getter message : String

    def initialize(@time, @appname, @host, @severity, @message)
    end
  end

  struct ContainerStat
    getter time : String
    getter name : String
    getter cpu : Float64
    getter mem : Float64       # bytes
    getter mem_limit : Float64 # bytes
    getter health : String

    def initialize(@time, @name, @cpu = 0.0, @mem = 0.0, @mem_limit = 0.0, @health = "")
    end

    def mem_mb : String
      "#{(@mem / (1024 * 1024)).round(0).to_i}MB"
    end

    def mem_pct : Float64
      return 0.0 if @mem_limit == 0
      ((@mem / @mem_limit) * 100).round(1)
    end
  end

  ENDPOINT = "http://#{HOST}:#{PORT}"

  private def self.client : HTTP::Client
    c = HTTP::Client.new(HOST, PORT)
    c.connect_timeout = 1.seconds   # same as Ruby: open_timeout = 1
    c.read_timeout = 3.seconds      # same as Ruby: read_timeout = 3
    c
  end

  # Basic auth — same as Ruby: req.basic_auth config.username, config.password
  private def self.basic_auth_header : HTTP::Headers
    credentials = Base64.strict_encode("#{USERNAME}:#{PASSWORD}")
    HTTP::Headers{"Authorization" => "Basic #{credentials}"}
  end

  # Authenticated probe — /health responds 200 anonymously, so we issue a real
  # query to surface 401s as ping failures instead of "no entries".
  def self.ping : Bool
    c = client
    params = URI::Params.encode({"db" => DATABASE, "q" => "SHOW MEASUREMENTS LIMIT 1"})
    response = c.get("/query?#{params}", headers: basic_auth_header)
    response.status_code == 200
  rescue
    false
  end

  # ─── Line Protocol write ───

  def self.write(lines : String, precision : String = "ns") : Bool
    c = client
    params = URI::Params.encode({"db" => DATABASE, "precision" => precision})
    response = c.post("/write?#{params}", headers: basic_auth_header, body: lines)
    response.status_code == 204
  rescue
    false
  end

  # ─── InfluxQL queries (v1.x API) ───

  def self.raw_query(influxql : String) : JSON::Any
    query(influxql)
  end

  private def self.query(influxql : String) : JSON::Any
    c = client
    params = URI::Params.encode({"db" => DATABASE, "q" => influxql})
    response = c.get("/query?#{params}", headers: basic_auth_header)
    unless response.status_code == 200
      raise "InfluxDB query failed (#{response.status_code}): #{response.body}"
    end
    JSON.parse(response.body)
  end

  # Extract series values from InfluxDB JSON response
  private def self.extract_series(result : JSON::Any) : {Array(String), Array(Array(JSON::Any))}
    series = result.dig?("results", 0, "series", 0)
    return {[] of String, [] of Array(JSON::Any)} unless series

    columns = series["columns"].as_a.map(&.as_s)
    values = series["values"].as_a.map(&.as_a)
    {columns, values}
  end

  # ─── Docker Logs from InfluxDB ───

  def self.query_docker_logs(
    container : String? = nil,
    host : String? = nil,
    search : String? = nil,
    lines : Int32 = 50,
    from : String = "1h"
  ) : Array(LogEntry)
    where_clauses = ["time > now() - #{from}"]
    if container
      where_clauses << "container_name =~ /#{escape(container)}/"
    end
    if host
      where_clauses << "host = '#{escape(host)}'"
    end
    if search
      where_clauses << "message =~ /#{escape(search)}/"
    end

    where = where_clauses.join(" AND ")
    q = "SELECT container_name, message FROM docker_log WHERE #{where} ORDER BY time DESC LIMIT #{lines}"

    result = query(q)
    columns, values = extract_series(result)

    entries = [] of LogEntry
    time_i = columns.index("time") || 0
    name_i = columns.index("container_name") || 1
    msg_i = columns.index("message") || 2

    values.reverse_each do |row|
      time_raw = row[time_i]?.try(&.as_s?) || ""
      name = row[name_i]?.try(&.as_s?) || "-"
      msg = row[msg_i]?.try(&.as_s?) || ""
      next if msg.empty?

      entries << LogEntry.new(
        time: format_time(time_raw),
        appname: name,
        host: "",
        severity: "info",
        message: msg
      )
    end
    entries
  end

  # ─── Container Stats from InfluxDB ───

  def self.query_container_cpu(host : String? = nil, from : String = "5m") : Array(ContainerStat)
    where = "time > now() - #{from}"
    where += " AND host = '#{escape(host)}'" if host
    q = "SELECT last(usage_percent) FROM docker_container_cpu WHERE #{where} GROUP BY container_name"

    result = query(q)
    stats = [] of ContainerStat
    series = result.dig?("results", 0, "series")
    return stats unless series

    series.as_a.each do |s|
      name = s.dig?("tags", "container_name").try(&.as_s?) || "-"
      vals = s["values"]?.try(&.as_a)
      next unless vals && !vals.empty?
      time = vals.last[0]?.try(&.as_s?) || ""
      cpu = vals.last[1]?.try(&.as_f?) || vals.last[1]?.try(&.as_i?).try(&.to_f) || 0.0
      stats << ContainerStat.new(time: format_time(time), name: name, cpu: cpu)
    end
    stats
  end

  def self.query_container_mem(host : String? = nil, from : String = "5m") : Array(ContainerStat)
    where = "time > now() - #{from}"
    where += " AND host = '#{escape(host)}'" if host
    q = "SELECT last(usage) FROM docker_container_mem WHERE #{where} GROUP BY container_name"

    result = query(q)
    stats = [] of ContainerStat
    series = result.dig?("results", 0, "series")
    return stats unless series

    series.as_a.each do |s|
      name = s.dig?("tags", "container_name").try(&.as_s?) || "-"
      vals = s["values"]?.try(&.as_a)
      next unless vals && !vals.empty?
      time = vals.last[0]?.try(&.as_s?) || ""
      mem = vals.last[1]?.try(&.as_f?) || vals.last[1]?.try(&.as_i?).try(&.to_f) || 0.0
      stats << ContainerStat.new(time: format_time(time), name: name, mem: mem)
    end
    stats
  end

  def self.query_container_health(host : String? = nil, from : String = "5m") : Array(ContainerStat)
    where = "time > now() - #{from}"
    where += " AND host = '#{escape(host)}'" if host
    q = "SELECT last(health_status) FROM docker_container_health WHERE #{where} GROUP BY container_name"

    result = query(q)
    stats = [] of ContainerStat
    series = result.dig?("results", 0, "series")
    return stats unless series

    series.as_a.each do |s|
      name = s.dig?("tags", "container_name").try(&.as_s?) || "-"
      vals = s["values"]?.try(&.as_a)
      next unless vals && !vals.empty?
      time = vals.last[0]?.try(&.as_s?) || ""
      health = vals.last[1]?.try(&.as_s?) || ""
      stats << ContainerStat.new(time: format_time(time), name: name, health: health)
    end
    stats
  end

  # ─── System metrics from InfluxDB ───

  def self.query_system_cpu(host : String? = nil, from : String = "5m") : Array({String, Float64})
    where = "cpu = 'cpu-total' AND time > now() - #{from}"
    where += " AND host = '#{escape(host)}'" if host
    group = host ? "time(1m)" : "time(1m), host"
    q = "SELECT mean(usage_idle) FROM cpu WHERE #{where} GROUP BY #{group}"

    result = query(q)
    entries = [] of {String, Float64}
    series = result.dig?("results", 0, "series")
    return entries unless series

    series.as_a.each do |s|
      h = s.dig?("tags", "host").try(&.as_s?) || ""
      vals = s["values"]?.try(&.as_a)
      next unless vals
      vals.each do |v|
        idle = v[1]?.try(&.as_f?) || v[1]?.try(&.as_i?).try(&.to_f)
        next unless idle
        entries << {h, (100.0 - idle).round(1)}
      end
    end
    entries
  end

  # ─── Available hosts ───

  def self.query_hosts : Array(String)
    q = "SHOW TAG VALUES FROM cpu WITH KEY = host"
    result = query(q)
    columns, values = extract_series(result)
    values.map { |v| v[1]?.try(&.as_s?) || "" }.reject(&.empty?)
  end

  # ─── CDR (Call Detail Records) from InfluxDB ───

  struct CdrEntry
    getter time : String
    getter caller_id : String
    getter callee : String
    getter duration : Int64
    getter direction : String
    getter host : String
    getter hangup_cause : String

    def initialize(@time, @caller_id = "", @callee = "", @duration = 0_i64,
                   @direction = "", @host = "", @hangup_cause = "")
    end
  end

  def self.query_cdr(
    host : String? = nil,
    lines : Int32 = 50,
    from : String = "24h"
  ) : Array(CdrEntry)
    where_clauses = ["time > now() - #{from}"]
    if host
      where_clauses << "host = '#{escape(host)}'"
    end

    where = where_clauses.join(" AND ")
    q = "SELECT caller_id_number, destination_number, duration, direction, host, hangup_cause FROM cdr WHERE #{where} ORDER BY time DESC LIMIT #{lines}"

    result = query(q)
    columns, values = extract_series(result)

    entries = [] of CdrEntry
    time_i = columns.index("time") || 0
    caller_i = columns.index("caller_id_number") || 1
    callee_i = columns.index("destination_number") || 2
    dur_i = columns.index("duration") || 3
    dir_i = columns.index("direction") || 4
    host_i = columns.index("host") || 5
    hangup_i = columns.index("hangup_cause") || 6

    values.reverse_each do |row|
      entries << CdrEntry.new(
        time: format_time(row[time_i]?.try(&.as_s?) || ""),
        caller_id: row[caller_i]?.try(&.as_s?) || "",
        callee: row[callee_i]?.try(&.as_s?) || "",
        duration: row[dur_i]?.try(&.as_i64?) || row[dur_i]?.try(&.as_f?).try(&.to_i64) || 0_i64,
        direction: row[dir_i]?.try(&.as_s?) || "",
        host: row[host_i]?.try(&.as_s?) || "",
        hangup_cause: row[hangup_i]?.try(&.as_s?) || "",
      )
    end
    entries
  rescue
    [] of CdrEntry
  end

  # ─── Legacy syslog query (compat with syslog command) ───

  def self.query_syslog(
    app : String? = nil,
    severity : String? = nil,
    search : String? = nil,
    lines : Int32 = 50,
    from : String = "-1h"
  ) : Array(LogEntry)
    # Normalize from: "-1h" → "1h" for InfluxQL
    range = from.lchop("-")
    query_docker_logs(container: app, search: search, lines: lines, from: range)
  end

  # ─── Helpers ───

  private def self.format_time(raw : String) : String
    if raw.includes?("T")
      raw.sub("T", " ").sub(/\.\d+Z$/, "").sub("Z", "")
    else
      raw
    end
  end

  private def self.escape(s : String) : String
    s.gsub("'", "\\'").gsub("\"", "\\\"")
  end
end
