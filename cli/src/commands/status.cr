require "admiral"
require "json"
require "../helpers/colors"
require "../helpers/table"
require "../helpers/docker"
require "../helpers/services"
require "../helpers/top_bar"

module VoIPAppz::Commands
  # `status` is the canonical "is the stack up?" view. It iterates the
  # Services catalog and joins it with `docker compose ps --format json`,
  # so missing/expected services surface as red rows rather than silently
  # being absent (which is what `docker ps` does).
  #
  # Exit codes:
  #   0  all expected services running and healthy
  #   3  one or more expected services not running
  #   4  running but unhealthy
  #
  # JSON shape (`--json`):
  # {
  #   "services": [{name, profile, container, state, health, uptime, port}],
  #   "summary":  {total, running, healthy, missing}
  # }
  class Status < Admiral::Command
    define_help description: "Show service status (covers `up` — what should be running vs reality)"

    define_flag profile : String,
      description: "Filter by profile: app, voip, all",
      default: "all",
      short: p
    define_flag json : Bool,
      description: "Emit machine-readable JSON",
      default: false
    define_flag watch : Bool,
      description: "Refresh every 2 seconds",
      default: false,
      short: w
    define_flag resources : Bool,
      description: "Append CPU/memory stats",
      default: false,
      short: r
    define_flag compact : Bool,
      description: "Print a one-line summary (used by the interactive console)",
      default: false
    define_flag bar : Bool,
      description: "Print the compact console top bar",
      default: false
    define_flag active : Bool,
      description: "Show active containers only",
      short: a,
      default: false

    EXIT_OK         = 0
    EXIT_DOWN       = 3
    EXIT_UNHEALTHY  = 4
    # Distinct from DOWN and UNHEALTHY: nothing was measured. "0 services, all
    # fine" would be a lie, and exit 3 would say the plane is down when we
    # never looked at it.
    EXIT_NO_PROJECT = 5

    def run
      ENV["VOIPAPPZ_JSON"] = "1" if flags.json

      if flags.watch
        loop do
          print "\e[2J\e[H"
          render_once
          sleep 2.seconds
        end
      else
        exit render_once
      end
    end

    private def render_once : Int32
      begin
        services = VoIPAppz::Services.for_profile(flags.profile)
      rescue e : VoIPAppz::Services::CatalogMissing
        STDERR.puts VoIPAppz::Colors.red(e.message.to_s)
        return EXIT_NO_PROJECT
      end
      ps = fetch_compose_ps
      rows = services.map { |s| build_row(s, ps[s.name]?) }
      rows = rows.reject { |row| row.state == "missing" } if flags.active

      if flags.json
        emit_json(rows)
      elsif flags.bar
        emit_bar(rows)
      elsif flags.compact
        emit_compact(rows)
      else
        emit_table(rows)
        if flags.resources
          puts ""
          puts VoIPAppz::Colors.bold("Resource Usage:")
          VoIPAppz::Docker.stats
        end
      end

      exit_code(rows)
    end

    private def emit_compact(rows : Array(Row))
      running = rows.count { |r| r.state == "running" }
      healthy = rows.count { |r| r.health == "healthy" }
      unhealthy = rows.count { |r| r.health == "unhealthy" }
      changing = rows.count { |r| r.state == "starting" || r.state == "restarting" || r.health == "starting" }

      dot = if unhealthy > 0
              VoIPAppz::Colors.red(VoIPAppz::Colors::BULLET)
            elsif changing > 0
              VoIPAppz::Colors.yellow(VoIPAppz::Colors::BULLET)
            elsif running > 0
              VoIPAppz::Colors.green(VoIPAppz::Colors::BULLET)
            else
              VoIPAppz::Colors.dim(VoIPAppz::Colors::BULLET)
            end

      summary = "#{running} running · #{healthy} healthy"
      summary += " · #{changing} starting" if changing > 0
      summary += " · #{unhealthy} unhealthy" if unhealthy > 0
      puts "  #{dot} #{VoIPAppz::Colors.bold("Stack")}  #{summary}"
    end

    private def emit_bar(rows : Array(Row))
      running = rows.count { |r| r.state == "running" }
      unhealthy = rows.count { |r| r.health == "unhealthy" }
      changing = rows.count do |r|
        r.state == "starting" || r.state == "restarting" || r.health == "starting"
      end
      state = if unhealthy > 0
                "degraded"
              elsif changing > 0
                "starting"
              elsif running > 0
                "running"
              else
                "offline"
              end
      puts VoIPAppz::Colors.cyan(VoIPAppz::TopBar.render(state, running, unhealthy))
    end

    private record Row,
      name : String,
      container : String,
      profile : String,
      icon : String,
      port : Int32?,
      state : String,    # running | exited | restarting | missing
      health : String,   # healthy | unhealthy | starting | none | -
      uptime : String

    # `docker compose ps --format json` emits one JSON object per line
    # (NDJSON). Returns a hash keyed by compose service name.
    private def fetch_compose_ps : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      exit_code, output = VoIPAppz::Docker.compose(["ps", "--format", "json", "--all"], capture: true)
      return result if exit_code != 0 || output.strip.empty?

      output.each_line do |line|
        line = line.strip
        next if line.empty?
        begin
          obj = JSON.parse(line)
          name = obj["Service"]?.try(&.as_s) || obj["Name"]?.try(&.as_s) || next
          result[name] = obj
        rescue JSON::ParseException
          next
        end
      end
      result
    end

    private def build_row(s : VoIPAppz::Services::Service, ps : JSON::Any?) : Row
      if ps.nil?
        Row.new(s.name, s.container, s.profiles.join("/"), s.icon, s.port, "missing", "-", "-")
      else
        state = ps["State"]?.try(&.as_s) || "unknown"
        health = ps["Health"]?.try(&.as_s) || "none"
        health = "-" if health.empty?
        uptime = ps["Status"]?.try(&.as_s) || "-"
        Row.new(s.name, s.container, s.profiles.join("/"), s.icon, s.port, state, health, uptime)
      end
    end

    private def emit_table(rows : Array(Row))
      summary = summarize(rows)

      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ROCKET} Service Status")
      puts ""

      columns = [
        VoIPAppz::Table::Column.new("Service", 18),
        VoIPAppz::Table::Column.new("Profile", 8),
        VoIPAppz::Table::Column.new("State", 12),
        VoIPAppz::Table::Column.new("Health", 12),
        VoIPAppz::Table::Column.new("Port", 6),
        VoIPAppz::Table::Column.new("Uptime", 28),
      ]

      table_rows = rows.map do |r|
        [
          "#{r.icon}  #{r.name}",
          r.profile,
          colorize_state(r.state),
          colorize_health(r.health),
          r.port ? r.port.to_s : VoIPAppz::Colors.dim("-"),
          VoIPAppz::Colors.dim(r.uptime),
        ]
      end

      puts VoIPAppz::Table.render(columns, table_rows, title: nil)

      puts ""
      msg = "#{summary[:running]}/#{summary[:total]} running, #{summary[:healthy]} healthy"
      msg += ", #{summary[:missing]} missing" if summary[:missing] > 0
      if summary[:running] == summary[:total] && summary[:missing] == 0
        puts VoIPAppz::Colors.success(msg)
      elsif summary[:missing] > 0
        puts VoIPAppz::Colors.error(msg)
      else
        puts VoIPAppz::Colors.warning(msg)
      end
    end

    private def emit_json(rows : Array(Row))
      summary = summarize(rows)
      payload = {
        "services" => rows.map { |r|
          {
            "name"      => r.name,
            "container" => r.container,
            "profile"   => r.profile,
            "state"     => r.state,
            "health"    => r.health,
            "uptime"    => r.uptime,
            "port"      => r.port,
          }
        },
        "summary" => summary,
      }
      puts payload.to_json
    end

    private def summarize(rows : Array(Row))
      {
        total:   rows.size,
        running: rows.count { |r| r.state == "running" },
        healthy: rows.count { |r| r.health == "healthy" },
        missing: rows.count { |r| r.state == "missing" },
      }
    end

    private def exit_code(rows : Array(Row)) : Int32
      return EXIT_DOWN if rows.any? { |r| r.state == "missing" || r.state == "exited" }
      return EXIT_UNHEALTHY if rows.any? { |r| r.health == "unhealthy" }
      EXIT_OK
    end

    private def colorize_state(state : String) : String
      case state
      when "running"             then VoIPAppz::Colors.green(state)
      when "starting", "restarting" then VoIPAppz::Colors.yellow(state)
      when "missing", "exited", "dead" then VoIPAppz::Colors.red(state)
      else                            VoIPAppz::Colors.dim(state)
      end
    end

    private def colorize_health(health : String) : String
      case health
      when "healthy"          then VoIPAppz::Colors.green(health)
      when "starting"         then VoIPAppz::Colors.yellow(health)
      when "unhealthy"        then VoIPAppz::Colors.red(health)
      else                       VoIPAppz::Colors.dim(health)
      end
    end
  end
end
