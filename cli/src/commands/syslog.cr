require "admiral"
require "../helpers/colors"
require "../helpers/influxdb"

module VoIPAppz::Commands
  class Syslog < Admiral::Command
    define_help description: "Query syslog entries from InfluxDB"

    define_flag app : String,
      description: "Filter by appname (e.g. kamailio, api, freeswitch)",
      short: a
    define_flag severity : String,
      description: "Filter by severity (e.g. info, error, warning)",
      short: s
    define_flag search : String,
      description: "Search message field (regex)"
    define_flag lines : Int32,
      description: "Number of lines to show",
      default: 50,
      short: n
    define_flag from : String,
      description: "Time range start (e.g. -1h, -30m, -6h)",
      default: "-1h"
    define_flag follow : Bool,
      description: "Follow mode (poll every 3s)",
      default: false,
      short: f

    SEVERITY_COLORS = {
      "emerg"    => VoIPAppz::Colors::RED,
      "alert"    => VoIPAppz::Colors::RED,
      "crit"     => VoIPAppz::Colors::RED,
      "err"      => VoIPAppz::Colors::RED,
      "error"    => VoIPAppz::Colors::RED,
      "warning"  => VoIPAppz::Colors::YELLOW,
      "warn"     => VoIPAppz::Colors::YELLOW,
      "notice"   => VoIPAppz::Colors::CYAN,
      "info"     => VoIPAppz::Colors::GREEN,
      "debug"    => VoIPAppz::Colors::DIM,
    }

    def run
      unless VoIPAppz::InfluxDB.ping
        STDERR.puts VoIPAppz::Colors.error("InfluxDB not reachable at #{VoIPAppz::InfluxDB::ENDPOINT}")
        STDERR.puts "  Start the app profile: voipappz up -p app --wait"
        exit 1
      end

      if flags.follow
        run_follow
      else
        run_once
      end
    end

    private def run_once
      entries = query_entries
      if entries.empty?
        puts VoIPAppz::Colors.dim("  No log entries found for the given filters.")
        return
      end
      entries.each { |e| print_entry(e) }
      puts ""
      puts VoIPAppz::Colors.dim("  #{entries.size} entries (from #{flags.from})")
    end

    private def run_follow
      puts VoIPAppz::Colors.info("Following syslog... (Ctrl+C to stop)")
      puts ""
      last_time : String? = nil

      loop do
        entries = query_entries(from: "-10s")
        entries.each do |e|
          next if last_time && e.time <= last_time.not_nil!
          print_entry(e)
          last_time = e.time
        end
        sleep 3.seconds
      end
    rescue ex : Exception
      # Ctrl+C or other interrupt
      puts "" unless ex.is_a?(IO::Error)
    end

    private def query_entries(from : String? = nil) : Array(VoIPAppz::InfluxDB::LogEntry)
      VoIPAppz::InfluxDB.query_syslog(
        app: flags.app,
        severity: flags.severity,
        search: flags.search,
        lines: flags.lines,
        from: from || flags.from
      )
    rescue ex
      STDERR.puts VoIPAppz::Colors.error("Query failed: #{ex.message}")
      [] of VoIPAppz::InfluxDB::LogEntry
    end

    private def print_entry(e : VoIPAppz::InfluxDB::LogEntry)
      sev_color = SEVERITY_COLORS[e.severity.downcase]? || VoIPAppz::Colors::RESET
      time_str = VoIPAppz::Colors.dim(e.time)
      sev_str = "#{sev_color}#{e.severity.ljust(8)}#{VoIPAppz::Colors::RESET}"
      app_str = VoIPAppz::Colors.cyan(e.appname.ljust(12))
      puts "#{time_str}  #{sev_str} #{app_str} #{e.message}"
    end
  end
end
