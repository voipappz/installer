require "admiral"
require "http/client"
require "json"
require "../helpers/colors"
require "../helpers/table"
require "../helpers/docker"
require "../helpers/services"
require "../helpers/influxdb"
require "../helpers/node_health"

module VoIPAppz::Commands
  class Monitor < Admiral::Command
    define_help description: "Interactive container monitor"

    define_flag interval : Int32,
      description: "Refresh interval in seconds",
      default: 2,
      short: i

    define_flag host : String,
      description: "Filter InfluxDB data by host",
      default: ""

    # Service list + metadata come from the shared catalog so monitor
    # stays aligned with `up` / `status` / `health`.
    # Uses container names (e.g. `postgres`, not the compose key `db`)
    # because everything below queries `docker ps` / `docker logs` /
    # `docker exec` directly.
    # From config/services.tsv via the catalog — memoized, so the file is read
    # once per run rather than on every keypress in the TUI loop.
    @@service_list : Array(String)?

    def self.service_list : Array(String)
      @@service_list ||= VoIPAppz::Services.all.map(&.container)
    end

    private def service_meta(key : String) : VoIPAppz::Services::Service
      VoIPAppz::Services.find?(key) || raise "Unknown service: #{key}"
    end

    enum View
      Containers  # main table view
      Logs        # docker logs for selected container
      Syslog      # influxdb syslog for selected container
      Health      # the voip plane's own checks, from the node itself
    end

    struct ContainerInfo
      property name : String
      property state : String
      property health : String
      property uptime : String

      def initialize(@name, @state = "stopped", @health = "none", @uptime = "-")
      end
    end

    # ─── State ───

    @selected : Int32 = 0
    @view : View = View::Containers
    @containers : Array(ContainerInfo) = [] of ContainerInfo
    @stats : Hash(String, {String, String, String, String, String}) = {} of String => {String, String, String, String, String}
    @log_lines : Array(String) = [] of String
    @syslog_lines : Array(String) = [] of String
    # nil means "the node did not answer", which renders differently from a
    # verdict with nothing down ("the node answered, everything is up").
    @node_health : VoIPAppz::NodeHealth::Verdict? = nil
    @cols : Int32 = 120
    @rows : Int32 = 40
    @last_refresh : Time = Time.utc
    @sort_col : Int32 = 0  # 0=name, 1=cpu, 2=mem
    @running : Bool = true

    def run
      @cols, @rows = terminal_size
      hide_cursor
      enable_raw_mode
      print "\e[2J\e[H"  # clear screen

      refresh_data

      # Input reader in background fiber
      spawn do
        while @running
          key = read_key
          handle_key(key) if key
        end
      end

      # Main render loop
      begin
        while @running
          now = Time.utc
          if (now - @last_refresh).total_seconds >= flags.interval
            refresh_data
          end
          @cols, @rows = terminal_size
          render
          sleep 0.1.seconds
        end
      ensure
        disable_raw_mode
        show_cursor
        print "\e[2J\e[H"
      end
    end

    # ─── Input handling ───

    private def read_key : String?
      buf = Bytes.new(8)
      bytes_read = STDIN.read(buf)
      return nil if bytes_read == 0

      seq = String.new(buf[0, bytes_read])

      if seq == "\e[A"
        "up"
      elsif seq == "\e[B"
        "down"
      elsif seq == "\e[C"
        "right"
      elsif seq == "\e[D"
        "left"
      elsif seq.starts_with?("\e[")
        "esc"
      elsif seq == "\e"
        "esc"
      else
        seq[0].to_s
      end
    rescue
      nil
    end

    private def handle_key(key : String)
      case @view
      when .containers?
        case key
        when "q"     then @running = false
        when "up", "k"
          @selected = (@selected - 1).clamp(0, self.class.service_list.size - 1)
        when "down", "j"
          @selected = (@selected + 1).clamp(0, self.class.service_list.size - 1)
        when "l", "\r", "\n"  # Enter or 'l'
          enter_logs_view
        when "s"
          enter_syslog_view
        when "h"
          enter_health_view
        when "r"
          refresh_data
        when "1"
          @sort_col = 0
        when "2"
          @sort_col = 1
        when "3"
          @sort_col = 2
        end
      when .health?
        case key
        when "q", "esc", "\e"
          @view = View::Containers
        when "r", "h"
          enter_health_view
        end
      when .logs?, .syslog?
        case key
        when "q", "esc", "\e"
          @view = View::Containers
        when "s"
          if @view.logs?
            enter_syslog_view
          else
            @view = View::Containers
          end
        when "l"
          if @view.syslog?
            enter_logs_view
          else
            @view = View::Containers
          end
        when "r"
          if @view.logs?
            enter_logs_view
          else
            enter_syslog_view
          end
        end
      end
    end

    private def enter_logs_view
      @view = View::Logs
      service = self.class.service_list[@selected]
      @log_lines = fetch_docker_logs(service, @rows - 8)
    end

    # The node probes its own plane on loopback and continuously, so this reads
    # its verdict rather than racing its own probes against it. A box mid-deploy
    # has no node answering yet — that is a line in the pane, not an error.
    private def enter_health_view
      @view = View::Health
      @node_health = VoIPAppz::NodeHealth.verdict
    end

    private def enter_syslog_view
      @view = View::Syslog
      service = self.class.service_list[@selected]
      @syslog_lines = fetch_syslog(service, @rows - 8)
    end

    # ─── Data fetching ───

    private def refresh_data
      @containers = fetch_containers
      @stats = fetch_stats
      @last_refresh = Time.utc
    end

    private def fetch_containers : Array(ContainerInfo)
      stdout = IO::Memory.new
      process = Process.new(
        "docker",
        ["ps", "-a", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}"],
        output: stdout, error: Process::Redirect::Close,
      )
      process.wait

      result = [] of ContainerInfo
      stdout.to_s.strip.split("\n").each do |line|
        next if line.empty?
        parts = line.split("\t")
        next if parts.size < 3
        name = parts[0]
        state = parts[1]
        status_str = parts[2]

        service_name = name.lchop("va-")
        next unless self.class.service_list.includes?(name) || self.class.service_list.includes?(service_name)

        health = fetch_health(name)
        uptime = parse_uptime(status_str)
        result << ContainerInfo.new(name: name, state: state, health: health, uptime: uptime)
      end
      result
    end

    private def fetch_health(container : String) : String
      stdout = IO::Memory.new
      Process.new("docker",
        ["inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", container],
        output: stdout, error: Process::Redirect::Close).wait
      stdout.to_s.strip
    rescue
      "none"
    end

    private def fetch_stats : Hash(String, {String, String, String, String, String})
      result = {} of String => {String, String, String, String, String}
      stdout = IO::Memory.new
      containers = Docker.running_containers
      return result if containers.empty?

      Process.new("docker",
        ["stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.PIDs}}"] + containers,
        output: stdout, error: Process::Redirect::Close).wait

      stdout.to_s.strip.split("\n").each do |line|
        next if line.empty?
        parts = line.split("\t")
        next if parts.size < 5
        name = parts[0]
        cpu = parts[1].strip
        mem_parts = parts[2].strip.split(" / ")
        mem_usage = mem_parts[0]? || "-"
        mem_limit = mem_parts[1]? || "-"
        net_io = parts[3].strip
        pids = parts[4].strip
        result[name] = {cpu, mem_usage, mem_limit, net_io, pids}
      end
      result
    end

    private def fetch_docker_logs(service : String, lines : Int32) : Array(String)
      container = Docker.resolve_container(service)
      stdout = IO::Memory.new
      Process.new("docker", ["logs", "--tail", lines.to_s, "--timestamps", container],
        output: stdout, error: stdout).wait
      stdout.to_s.strip.split("\n").last(lines)
    rescue
      ["(no logs available)"]
    end

    private def fetch_syslog(service : String, lines : Int32) : Array(String)
      entries = InfluxDB.query_syslog(app: service, lines: [lines, 100].min, from: "-1h")
      if entries.empty?
        return ["(no syslog entries from InfluxDB for '#{service}')"]
      end
      entries.map do |e|
        sev_color = case e.severity.downcase
                    when "err", "error", "crit", "alert", "emerg" then Colors::RED
                    when "warning", "warn"                         then Colors::YELLOW
                    when "notice"                                  then Colors::CYAN
                    when "info"                                    then Colors::GREEN
                    else                                                Colors::DIM
                    end
        "#{Colors::DIM}#{e.time}#{Colors::RESET}  #{sev_color}#{e.severity.ljust(8)}#{Colors::RESET} #{e.message}"
      end
    rescue ex
      ["(InfluxDB error: #{ex.message})"]
    end

    # ─── Rendering ───

    private def render
      print "\e[H"  # cursor home (no clear — reduces flicker)

      case @view
      when .containers? then render_containers
      when .logs?       then render_log_view("Docker Logs")
      when .syslog?     then render_log_view("Syslog (InfluxDB)")
      when .health?     then render_health_view
      end

      # Clear any leftover lines from previous frame
      print "\e[J"
      STDOUT.flush
    end

    private def render_containers
      running = @containers.count { |c| c.state == "running" }
      total_svc = self.class.service_list.size
      healthy = @containers.count { |c| c.health == "healthy" }
      now = Time.local.to_s("%H:%M:%S")

      # Header bar
      header = " VoIPAppz Monitor"
      status_right = "#{running}/#{total_svc} running  #{healthy} healthy  #{now} "
      pad = @cols - visible_len(header) - visible_len(status_right)
      pad = 1 if pad < 1
      puts "#{Colors::BG_GREEN}#{Colors::BOLD}#{header}#{" " * pad}#{status_right}#{Colors::RESET}"
      puts ""

      # Table header
      print_table_header

      # Container rows
      self.class.service_list.each_with_index do |service, idx|
        selected = idx == @selected
        print_container_row(service, idx, selected)
      end

      # Table bottom border
      puts "  #{Table::BL}#{Table::H * 16}#{Table::BJ}#{Table::H * 12}#{Table::BJ}#{Table::H * 12}#{Table::BJ}#{Table::H * 10}#{Table::BJ}#{Table::H * 20}#{Table::BJ}#{Table::H * 20}#{Table::BJ}#{Table::H * 7}#{Table::BJ}#{Table::H * 16}#{Table::BR}"

      # CPU/Memory sparkline for selected container
      puts ""
      selected_svc = self.class.service_list[@selected]
      st = @stats[selected_svc]? || @stats["va-#{selected_svc}"]?
      if st
        cpu_val = st[0].gsub("%", "").strip.to_f? || 0.0
        mem_val = parse_mem_pct(st[1], st[2]).to_f? || 0.0
        bar_w = [(@cols - 30), 20].max
        bar_w = [bar_w, 50].min

        cpu_bar = resource_bar(cpu_val, bar_w)
        mem_bar = resource_bar(mem_val, bar_w)

        puts "  #{Colors.bold(selected_svc)}"
        puts "  CPU #{cpu_bar} #{st[0]}"
        puts "  MEM #{mem_bar} #{st[1]} / #{st[2]}"
      end

      # Footer with keybindings
      puts ""
      footer_items = [
        "#{Colors::BOLD}#{Colors::CYAN}\u2191\u2193#{Colors::RESET} navigate",
        "#{Colors::BOLD}#{Colors::CYAN}l#{Colors::RESET} logs",
        "#{Colors::BOLD}#{Colors::CYAN}s#{Colors::RESET} syslog",
        "#{Colors::BOLD}#{Colors::CYAN}h#{Colors::RESET} health",
        "#{Colors::BOLD}#{Colors::CYAN}r#{Colors::RESET} refresh",
        "#{Colors::BOLD}#{Colors::CYAN}q#{Colors::RESET} quit",
      ]
      puts "  #{footer_items.join("  #{Colors::DIM}│#{Colors::RESET}  ")}"
    end

    private def print_table_header
      puts "  #{Table::TL}#{Table::H * 16}#{Table::TJ}#{Table::H * 12}#{Table::TJ}#{Table::H * 12}#{Table::TJ}#{Table::H * 10}#{Table::TJ}#{Table::H * 20}#{Table::TJ}#{Table::H * 20}#{Table::TJ}#{Table::H * 7}#{Table::TJ}#{Table::H * 16}#{Table::TR}"
      puts "  #{Table::V} #{"Container".ljust(14)} #{Table::V} #{"State".ljust(10)} #{Table::V} #{"Health".ljust(10)} #{Table::V} #{"CPU %".ljust(8)} #{Table::V} #{"Memory".ljust(18)} #{Table::V} #{"Net I/O".ljust(18)} #{Table::V} #{"PID".ljust(5)} #{Table::V} #{"Uptime".ljust(14)} #{Table::V}"
      puts "  #{Table::LJ}#{Table::H * 16}#{Table::CJ}#{Table::H * 12}#{Table::CJ}#{Table::H * 12}#{Table::CJ}#{Table::H * 10}#{Table::CJ}#{Table::H * 20}#{Table::CJ}#{Table::H * 20}#{Table::CJ}#{Table::H * 7}#{Table::CJ}#{Table::H * 16}#{Table::RJ}"
    end

    private def print_container_row(service : String, idx : Int32, selected : Bool)
      meta = service_meta(service)
      ci = @containers.find { |c| c.name == service || c.name == "va-#{service}" }
      st = @stats[service]? || @stats["va-#{service}"]?

      if ci
        state_str = format_state(ci.state)
        health_str = format_health(ci.health)
        cpu = st ? format_cpu(st[0]) : Colors.dim("-")
        mem = st ? "#{st[1]} / #{st[2]}" : "-"
        net = st ? st[3] : "-"
        pids = st ? st[4] : "-"
        uptime = ci.uptime
        name_str = "#{meta.icon}  #{service}"
      else
        state_str = Colors.dim("stopped")
        health_str = Colors.dim("-")
        cpu = Colors.dim("-")
        mem = "-"
        net = "-"
        pids = "-"
        uptime = "-"
        name_str = "#{meta.icon}  #{Colors.dim(service)}"
      end

      # Build cells with proper padding
      name_cell = pad_cell(name_str, 14)
      state_cell = pad_cell(state_str, 10)
      health_cell = pad_cell(health_str, 10)
      cpu_cell = pad_cell(cpu, 8)
      mem_cell = pad_cell(mem, 18)
      net_cell = pad_cell(net, 18)
      pid_cell = pad_cell(pids, 5)
      uptime_cell = pad_cell(uptime, 14)

      row = "  #{Table::V} #{name_cell} #{Table::V} #{state_cell} #{Table::V} #{health_cell} #{Table::V} #{cpu_cell} #{Table::V} #{mem_cell} #{Table::V} #{net_cell} #{Table::V} #{pid_cell} #{Table::V} #{uptime_cell} #{Table::V}"

      if selected
        # Highlight selected row
        print "#{Colors::BOLD}\e[7m"  # reverse video
        puts row
        print Colors::RESET
      else
        puts row
      end
    end

    private def render_health_view
      puts "#{Colors::BG_GREEN}#{Colors::BOLD} Node health #{Colors::RESET}  #{Colors::DIM}#{VoIPAppz::NodeHealth.url}#{Colors::RESET}"
      puts Colors.divider(@cols)

      if verdict = @node_health
        line = verdict.metrics_line
        puts "  #{Colors::DIM}#{line}#{Colors::RESET}" unless line.empty?
        if verdict.down.empty?
          puts "  #{Colors::GREEN}all #{verdict.total} checks passing#{Colors::RESET}"
        else
          # Only failures are listed: the node reports up/total plus a
          # down-list, and a screen of greens buries the one red.
          verdict.down.first(@rows - 6).each do |entry|
            key, error = VoIPAppz::NodeHealth.split_down(entry)
            puts "  #{Colors::RED}●#{Colors::RESET} #{key.ljust(28)} #{Colors::DIM}#{error}#{Colors::RESET}"
          end
          puts Colors.divider(@cols)
          puts "  #{Colors::RED}#{verdict.failing} of #{verdict.total} checks failing#{Colors::RESET}"
        end
      else
        # Not an error state worth shouting about here: the node is a service
        # like any other and may simply not be up yet.
        puts "  #{Colors::YELLOW}the node is not answering at #{VoIPAppz::NodeHealth.url}#{Colors::RESET}"
        puts "  #{Colors::DIM}`voipappz up` starts it; VA_NODE_PORT overrides the port#{Colors::RESET}"
      end
    end

    private def render_log_view(title : String)
      service = self.class.service_list[@selected]
      meta = service_meta(service)

      # Header bar
      tab_logs = @view.logs? ? "#{Colors::BG_GREEN}#{Colors::BOLD} Logs #{Colors::RESET}" : "#{Colors::DIM} Logs #{Colors::RESET}"
      tab_syslog = @view.syslog? ? "#{Colors::BG_GREEN}#{Colors::BOLD} Syslog #{Colors::RESET}" : "#{Colors::DIM} Syslog #{Colors::RESET}"

      header = " #{meta.icon}  #{service} "
      puts "#{Colors::BG_GREEN}#{Colors::BOLD}#{header}#{Colors::RESET}  #{tab_logs}  #{tab_syslog}"
      puts Colors.divider(@cols)

      # Log content
      lines = @view.logs? ? @log_lines : @syslog_lines
      max_lines = @rows - 6
      display_lines = lines.last(max_lines)

      display_lines.each do |line|
        truncated = truncate(line, @cols - 2)
        puts truncated
      end

      # Pad remaining space
      remaining = max_lines - display_lines.size
      remaining.times { puts "" } if remaining > 0

      # Footer
      puts Colors.divider(@cols)
      footer_items = [
        "#{Colors::BOLD}#{Colors::CYAN}l#{Colors::RESET} logs",
        "#{Colors::BOLD}#{Colors::CYAN}s#{Colors::RESET} syslog",
        "#{Colors::BOLD}#{Colors::CYAN}r#{Colors::RESET} refresh",
        "#{Colors::BOLD}#{Colors::CYAN}q#{Colors::RESET}/#{Colors::BOLD}#{Colors::CYAN}esc#{Colors::RESET} back",
      ]
      puts "  #{footer_items.join("  #{Colors::DIM}│#{Colors::RESET}  ")}"
    end

    # ─── Formatting ───

    private def format_state(state : String) : String
      case state
      when "running"    then "#{Colors::GREEN}#{Colors::BOLD}running#{Colors::RESET}"
      when "exited"     then "#{Colors::RED}exited#{Colors::RESET}"
      when "paused"     then "#{Colors::YELLOW}paused#{Colors::RESET}"
      when "restarting" then "#{Colors::YELLOW}restart#{Colors::RESET}"
      when "created"    then "#{Colors::DIM}created#{Colors::RESET}"
      else                   Colors.dim(state)
      end
    end

    private def format_health(health : String) : String
      case health
      when "healthy"   then "#{Colors::GREEN}#{Colors::CHECK} healthy#{Colors::RESET}"
      when "unhealthy" then "#{Colors::RED}#{Colors::CROSS} unhlthy#{Colors::RESET}"
      when "starting"  then "#{Colors::YELLOW}#{Colors::CLOCK} start#{Colors::RESET}"
      else                  Colors.dim("-")
      end
    end

    private def format_cpu(cpu : String) : String
      val = cpu.gsub("%", "").strip.to_f? || 0.0
      if val > 80
        "#{Colors::RED}#{Colors::BOLD}#{cpu}#{Colors::RESET}"
      elsif val > 50
        "#{Colors::YELLOW}#{cpu}#{Colors::RESET}"
      else
        "#{Colors::GREEN}#{cpu}#{Colors::RESET}"
      end
    end

    private def resource_bar(pct : Float64, width : Int32) : String
      filled = ((pct / 100.0) * width).to_i.clamp(0, width)
      empty = width - filled
      color = pct > 80 ? Colors::RED : (pct > 50 ? Colors::YELLOW : Colors::GREEN)
      "#{color}#{"█" * filled}#{Colors::DIM}#{"░" * empty}#{Colors::RESET}"
    end

    private def pad_cell(text : String, width : Int32) : String
      vlen = visible_len(text)
      padding = width - vlen
      padding = 0 if padding < 0
      "#{text}#{" " * padding}"
    end

    private def visible_len(text : String) : Int32
      text.gsub(/\e\[[0-9;]*m/, "").size
    end

    private def truncate(text : String, max : Int32) : String
      vlen = visible_len(text)
      return text if vlen <= max || max <= 0
      # Simple truncation (may cut ANSI codes, but acceptable for log lines)
      result = ""
      count = 0
      i = 0
      while i < text.size && count < max
        if text[i] == '\e'
          # Pass through ANSI escape
          end_idx = text.index('m', i)
          if end_idx
            result += text[i..end_idx]
            i = end_idx + 1
          else
            result += text[i].to_s
            i += 1
            count += 1
          end
        else
          result += text[i].to_s
          i += 1
          count += 1
        end
      end
      result + Colors::RESET
    end

    private def parse_uptime(status : String) : String
      if status =~ /Up\s+(.+)/
        $1.gsub(" (healthy)", "").gsub(" (unhealthy)", "").strip
      elsif status =~ /Exited.*?(\d+\s+\w+)\s+ago/
        "down #{$1}"
      else
        s = status[0, 14]? || status
        s
      end
    end

    private def parse_mem_pct(usage : String, limit : String) : String
      u = parse_mem_bytes(usage)
      l = parse_mem_bytes(limit)
      return "0" if l == 0
      ((u / l) * 100).round(1).to_s
    end

    private def parse_mem_bytes(s : String) : Float64
      s = s.strip
      if s =~ /^([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)/i
        val = $1.to_f
        unit = $2.downcase
        case unit
        when "gib", "gb" then val * 1073741824
        when "mib", "mb" then val * 1048576
        when "kib", "kb" then val * 1024
        else                   val
        end
      else
        0.0
      end
    end

    # ─── Terminal control ───

    private def terminal_size : {Int32, Int32}
      cols_io = IO::Memory.new
      rows_io = IO::Memory.new
      Process.new("tput", ["cols"], output: cols_io, error: Process::Redirect::Close).wait
      Process.new("tput", ["lines"], output: rows_io, error: Process::Redirect::Close).wait
      c = cols_io.to_s.strip.to_i? || 120
      r = rows_io.to_s.strip.to_i? || 40
      {[c, 80].max, [r, 20].max}
    rescue
      {120, 40}
    end

    private def hide_cursor
      print "\e[?25l"
    end

    private def show_cursor
      print "\e[?25h"
    end

    @tty : Bool = false

    private def enable_raw_mode
      if File.exists?("/dev/tty")
        @tty = system("stty raw -echo -icanon min 0 time 0 < /dev/tty 2>/dev/null")
      end
    end

    private def disable_raw_mode
      if @tty
        system("stty sane < /dev/tty 2>/dev/null")
      end
    end
  end
end
