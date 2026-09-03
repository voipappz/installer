require "admiral"
require "json"
require "../helpers/colors"
require "../helpers/node_health"
require "../helpers/node_capture"
require "../helpers/sip_capture_view"

module VoIPAppz::Commands
  # `voipappz monitor` INSIDE THE NODE.
  #
  # The development `monitor` (monitor.cr) is a docker-plane TUI: every pane
  # comes from `docker ps` / `docker logs` / `docker exec` across the host
  # compose services, which is why the runtime binary could not carry it — the
  # container has no docker socket, by decision. This is the same screen with
  # every source swapped for the node's own answers: /health/node for the
  # checks and counters, /capture for SIP capture, and nothing else. It asks,
  # it draws, it keeps nothing.
  #
  # Two tabs, and ONE terminal — which is the point. `1 Node` is the health
  # board and the plane counters. `c` opens `2 Capture`: the sngrep screen,
  # fed by the same session-gated `node.<uuid>.hep.sip` subject
  # `voipappz sbc hep tail` reads, so an operator no longer needs a second
  # window to see the SIP behind a red check. The drawing lives in
  # `VoIPAppz::SipCaptureView` (pure, no socket); this command only owns the
  # live session and the keys.
  class NodeMonitor < Admiral::Command
    define_help description: "Interactive node monitor: health, plane counters, SIP capture"

    define_flag interval : Int32, description: "Refresh interval in seconds", default: 2, short: i
    define_flag once : Bool, description: "Draw one frame and exit (no terminal needed)", default: false
    define_flag capture : Bool, description: "Open on the SIP capture view instead of the node board", default: false
    define_flag capture_seconds : Int32,
      description: "With --capture, collect live SIP for this many seconds before drawing (0 = do not open a session)",
      default: 0

    ESC = "\e"

    @verdict : VoIPAppz::NodeHealth::Verdict? = nil
    @capture : JSON::Any? = nil
    @cols : Int32 = 120
    @rows : Int32 = 40
    @last_refresh : Time = Time.unix(0)
    @running : Bool = true
    @tty : Bool = false
    @capture_view = VoIPAppz::SipCaptureView.new
    @capture_mode : Bool = false
    @session : VoIPAppz::NodeCapture::Session? = nil
    @subject : String = ""

    def run
      refresh
      @capture_mode = flags.capture
      if flags.once
        # The escape hatch the switch proof uses: with a window, open a real
        # session, collect, draw and leave; without one, draw the empty view.
        # Either way it returns — an empty capture is a line, not a hang.
        collect_once(flags.capture_seconds) if @capture_mode && flags.capture_seconds > 0
        puts frame.join("\n")
        return
      end
      start_capture if @capture_mode
      @cols, @rows = terminal_size
      print "#{ESC}[?25l"
      enable_raw_mode
      print "#{ESC}[2J#{ESC}[H"
      spawn do
        while @running
          key = read_key
          handle_key(key) if key
        end
      end
      begin
        while @running
          refresh if (Time.utc - @last_refresh).total_seconds >= flags.interval
          @cols, @rows = terminal_size
          print "#{ESC}[H"
          frame.each { |l| print l, "#{ESC}[K\n" }
          print "#{ESC}[J"
          sleep 0.1.seconds
        end
      ensure
        stop_capture
        disable_raw_mode
        print "#{ESC}[?25h#{ESC}[2J#{ESC}[H"
      end
    end

    private def refresh
      @verdict = VoIPAppz::NodeHealth.verdict
      @capture = VoIPAppz::NodeCapture.state
      @last_refresh = Time.utc
    end

    private def handle_key(key : String)
      if @capture_mode
        # The view owns every key while it is open; `false` is it asking to be
        # closed, which is also when the node stops publishing to us.
        unless @capture_view.handle_key(key)
          @capture_mode = false
          stop_capture
        end
        return
      end
      case key
      when "q", "esc" then @running = false
      when "r"        then refresh
      when "c"
        @capture_mode = true
        start_capture
      end
    end

    # ── the live session ──────────────────────────────────────────────────
    #
    # A viewer session is what makes the node publish at all (see
    # NodeCapture::Session): opening the tab opens the window, leaving it
    # closes the window immediately rather than waiting for the ttl to lapse.
    # Every failure here is a LINE in the view, never an exception out of a
    # TUI that has the terminal in raw mode.

    private def start_capture
      return if @session
      @capture_view.error = nil
      begin
        url = VoIPAppz::NodeCapture.broker_url
        uuid = VoIPAppz::NodeCapture.node_uuid
        @subject = VoIPAppz::NodeCapture.stream_subject(uuid)
        session = VoIPAppz::NodeCapture::Session.new(url, uuid)
      rescue ex
        @capture_view.error = ex.message.to_s
        return
      end
      @session = session
      @capture_view.status = "live on #{@subject}"
      spawn do
        begin
          session.each { |line| @capture_view.add(line); true }
        rescue ex
          @capture_view.error = ex.message.to_s
        ensure
          @capture_view.status = nil
        end
      end
    end

    private def stop_capture
      session = @session
      return unless session
      @session = nil
      session.stop
      session.close
      @capture_view.status = nil
    end

    # `--once --capture --capture-seconds N`: a real session, bounded, no tty.
    private def collect_once(seconds : Int32)
      url = VoIPAppz::NodeCapture.broker_url
      uuid = VoIPAppz::NodeCapture.node_uuid
      @subject = VoIPAppz::NodeCapture.stream_subject(uuid)
      session = VoIPAppz::NodeCapture::Session.new(url, uuid)
      begin
        session.each(seconds.seconds) { |line| @capture_view.add(line); true }
        @capture_view.status = "collected #{seconds}s on #{@subject}"
      ensure
        session.close
      end
    rescue ex
      @capture_view.error = ex.message.to_s
    end

    # ── the frame, as lines: pure enough to print once without a tty ─────
    def frame : Array(String)
      lines = [] of String
      v = @verdict
      badge = if v.nil?
                "#{Colors::YELLOW}● node not answering#{Colors::RESET}"
              elsif v.ok
                "#{Colors::GREEN}● #{v.up}/#{v.total} checks#{Colors::RESET}"
              else
                "#{Colors::RED}● #{v.failing}/#{v.total} failing#{Colors::RESET}"
              end
      uuid = ENV["NODE_UUID"]? || ENV["VA_NODE_UUID"]? || ""
      keys = @capture_mode ? @capture_view.hint : "r refresh  c capture  q quit"
      lines << "#{Colors::BOLD} VoIPAppz node #{Colors::RESET} #{Colors::DIM}#{uuid}#{Colors::RESET}   #{badge}   #{tabs}  #{Colors::DIM}#{keys}#{Colors::RESET}"
      lines << Colors.divider(@cols)
      return capture_frame(lines) if @capture_mode
      if v.nil?
        lines << "  #{Colors::YELLOW}the node is not answering at #{VoIPAppz::NodeHealth.url}#{Colors::RESET}"
      else
        %w[sip media control capture license agent system].each do |group|
          checks = v.checks[group]?
          next unless checks
          cells = checks.map do |key, ok|
            name = key.sub("#{group}_", "")
            note = v.warn.find(&.starts_with?("#{key}:")).try { |w| VoIPAppz::NodeHealth.split_down(w)[1] }
            err = v.down.find(&.starts_with?("#{key}:")).try { |d| VoIPAppz::NodeHealth.split_down(d)[1] }
            dot = if !ok
                    "#{Colors::RED}●#{Colors::RESET}"
                  elsif note
                    "#{Colors::YELLOW}⚠#{Colors::RESET}"
                  else
                    "#{Colors::GREEN}●#{Colors::RESET}"
                  end
            extra = err || note
            "#{dot} #{name}#{extra ? " #{Colors::DIM}#{extra}#{Colors::RESET}" : ""}"
          end
          lines << "  #{Colors::BOLD}#{group.ljust(9)}#{Colors::RESET}#{cells.join("   ")}"
        end
        lines << Colors.divider(@cols)
        line = v.metrics_line
        lines << "  #{line}" unless line.empty?
        if c = @capture
          rx = c["hep_packets_received_total"]?.try(&.as_i64?) || 0
          wr = c["hep_sip_written_total"]?.try(&.as_i64?) || 0
          trace = c["kamailio_trace_on"]?
          trace_s = trace.nil? || trace.raw.nil? ? "unknown" : (trace.as_bool ? "on" : "off")
          streaming = (c["streaming"]?.try(&.as_bool?) || false) ? "  live session open" : ""
          lines << "  hep rx #{rx} · written #{wr} · trace #{trace_s}#{streaming}   #{Colors::DIM}(voipappz sbc hep tail)#{Colors::RESET}"
        end
      end
      lines << Colors.divider(@cols)
      lines << "  #{Colors::DIM}refreshed #{(Time.utc - @last_refresh).total_seconds.to_i}s ago · #{VoIPAppz::NodeHealth.url}#{Colors::RESET}"
      lines
    end

    private def tabs : String
      if @capture_mode
        "#{Colors::DIM}1 Node#{Colors::RESET} #{Colors::BOLD}[2 Capture]#{Colors::RESET}"
      else
        "#{Colors::BOLD}[1 Node]#{Colors::RESET} #{Colors::DIM}2 Capture#{Colors::RESET}"
      end
    end

    # The sngrep tab. The header and the footer are this command's; every line
    # between them is the view's, drawn from what it has been fed.
    private def capture_frame(lines : Array(String)) : Array(String)
      body = {@rows - 5, 4}.max
      lines.concat(@capture_view.frame(@cols, body))
      lines << Colors.divider(@cols)
      state = if message = @capture_view.error
                "#{Colors::YELLOW}#{message}#{Colors::RESET}"
              else
                @capture_view.status || "no live session"
              end
      lines << "  #{Colors::DIM}#{@capture_view.dialog_count} dialog(s) · " \
             "#{@capture_view.message_count} message(s) · #{state}#{Colors::RESET}"
      lines
    end

    # ── terminal plumbing (same as monitor.cr) ────────────────────────────
    #
    # Arrows are named rather than folded into "esc": the capture view uses
    # them, and a view that quit on every arrow key would be unusable.
    private def read_key : String?
      buf = Bytes.new(8)
      n = STDIN.read(buf)
      return nil if n == 0
      seq = String.new(buf[0, n])
      case seq
      when "#{ESC}[A" then "up"
      when "#{ESC}[B" then "down"
      when "#{ESC}[C" then "right"
      when "#{ESC}[D" then "left"
      else
        seq.starts_with?(ESC) ? "esc" : seq[0].to_s
      end
    rescue
      nil
    end

    private def terminal_size : {Int32, Int32}
      cols_io = IO::Memory.new
      rows_io = IO::Memory.new
      Process.new("tput", ["cols"], output: cols_io, error: Process::Redirect::Close).wait
      Process.new("tput", ["lines"], output: rows_io, error: Process::Redirect::Close).wait
      {cols_io.to_s.strip.to_i? || 120, rows_io.to_s.strip.to_i? || 40}
    rescue
      {120, 40}
    end

    private def enable_raw_mode
      @tty = system("stty raw -echo -icanon min 0 time 0 < /dev/tty 2>/dev/null") if File.exists?("/dev/tty")
    end

    private def disable_raw_mode
      system("stty sane < /dev/tty 2>/dev/null") if @tty
    end
  end
end
