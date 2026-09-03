require "./colors"
require "./node_capture"

module VoIPAppz
  # The sngrep screen, inside the node's own monitor.
  #
  # Everything here is PURE. It is fed `NodeCapture::Line`s — the very
  # documents `voipappz sbc hep tail` reads off `node.<uuid>.hep.sip` — and it
  # gives back an array of strings. No socket, no terminal, and no clock of its
  # own (`now` is a parameter), which is what lets `monitor --once --capture`
  # and the spec draw the same frame the TUI draws.
  #
  # Two screens, the two sngrep screens:
  #
  #   List  one row per Call-ID, NEWEST AT THE BOTTOM — it reads like a tail,
  #         and the selection starts on the newest dialog.
  #   Flow  the ladder for one dialog: a column per endpoint (host:port), one
  #         arrow per message labelled with its method or response code, and
  #         the selected message's headers beside it (>= 100 columns) or
  #         beneath it (narrower, which is what 80 columns gets).
  #
  # Nothing is fetched here and nothing is stored anywhere else: the node keeps
  # no history for the live path, so what this holds is what has crossed the
  # box since the view was opened.
  class SipCaptureView
    # BOUNDED ON PURPOSE. A busy node mints Call-IDs forever, and a capture
    # view that keeps all of them is a memory leak with a user interface. The
    # oldest dialog is evicted past MAX_DIALOGS and a single dialog stops
    # growing past MAX_MESSAGES; both drop the OLDEST, so what is on screen now
    # is what survives. `dropped` counts what a dialog lost, so the flow never
    # silently claims to be complete.
    MAX_DIALOGS  = 200
    MAX_MESSAGES = 200

    # What the message pane shows, in this order. Everything else a message
    # carries is counted, not printed — a pane that scrolls off the bottom is
    # not a pane.
    HEADERS = %w[Via From To CSeq Call-ID Max-Forwards Content-Length User-Agent]

    # SIP's compact forms are legal on the wire and unreadable in a pane.
    COMPACT = {
      "v" => "Via", "f" => "From", "t" => "To", "i" => "Call-ID",
      "l" => "Content-Length", "m" => "Contact", "c" => "Content-Type",
      "s" => "Subject", "k" => "Supported", "e" => "Content-Encoding",
    }

    CANON = {
      "via" => "Via", "from" => "From", "to" => "To", "cseq" => "CSeq",
      "call-id" => "Call-ID", "max-forwards" => "Max-Forwards",
      "content-length" => "Content-Length", "user-agent" => "User-Agent",
      "contact" => "Contact", "content-type" => "Content-Type",
    }

    # Minimum ladder column before endpoints start being hidden instead of
    # squeezed. Below this a "host:port" heading is unreadable anyway.
    MIN_COLUMN = 12
    MAX_COLUMN = 26
    # The pane sits beside the ladder only when there is room for both.
    SIDE_PANE_AT = 100
    SIDE_PANE_W  =  44

    enum Mode
      List
      Flow
    end

    record Message, line : VoIPAppz::NodeCapture::Line, at : Time

    # One Call-ID and every message seen on it, oldest first.
    class Dialog
      getter call_id : String
      getter messages = [] of Message
      getter first_seen : Time
      getter dropped = 0
      property last_seen : Time

      def initialize(@call_id : String, @first_seen : Time)
        @last_seen = @first_seen
      end

      def add(message : Message)
        @messages << message
        @last_seen = message.at if message.at > @last_seen
        if @messages.size > MAX_MESSAGES
          @messages.shift
          @dropped += 1
        end
      end

      # The method the dialog is about: the first request, or — when the first
      # thing seen was a reply — the CSeq method that reply belongs to.
      def first_method : String
        if request = @messages.find(&.line.request?)
          request.line.method
        else
          @messages.first?.try(&.line.transaction_method) || ""
        end
      end

      def from : String
        @messages.first?.try(&.line.from) || ""
      end

      def to : String
        @messages.first?.try(&.line.to) || ""
      end

      # The last reply seen, which is the state a dialog is in.
      def last_response : String
        @messages.reverse_each do |m|
          return m.line.label unless m.line.request?
        end
        ""
      end

      # Every host:port this dialog touched, in first-appearance order — the
      # ladder's columns.
      def endpoints : Array(String)
        eps = [] of String
        @messages.each do |m|
          eps << m.line.src if !m.line.src.empty? && !eps.includes?(m.line.src)
          eps << m.line.dst if !m.line.dst.empty? && !eps.includes?(m.line.dst)
        end
        eps
      end
    end

    getter mode : Mode = Mode::List
    getter received = 0
    # A note the monitor sets: what the live session is doing right now.
    property status : String? = nil
    # A failure that must READ as a line, never as a crash and never as a hang.
    property error : String? = nil

    @dialogs = {} of String => Dialog
    # Oldest first. The newest dialog is therefore the LAST row on screen.
    @order = [] of String
    # Selection follows the Call-ID, not the row index: rows shift under it
    # every time a new dialog arrives.
    @selected_call_id : String? = nil
    @selected_message = 0
    @list_top = 0
    @flow_top = 0

    def dialog_count : Int32
      @order.size
    end

    def message_count : Int32
      total = 0
      @dialogs.each_value { |d| total += d.messages.size }
      total
    end

    def add(line : VoIPAppz::NodeCapture::Line, now : Time = Time.utc)
      @received += 1
      at = self.class.parse_ts(line.ts) || now
      call_id = line.call_id.empty? ? "(no Call-ID)" : line.call_id
      dialog = @dialogs[call_id]?
      unless dialog
        dialog = Dialog.new(call_id, at)
        @dialogs[call_id] = dialog
        @order << call_id
        if @order.size > MAX_DIALOGS
          evicted = @order.shift
          @dialogs.delete(evicted)
          @selected_call_id = nil if @selected_call_id == evicted
        end
      end
      dialog.add(Message.new(line, at))
    end

    def self.parse_ts(ts : String) : Time?
      return nil if ts.empty?
      Time.parse_rfc3339(ts)
    rescue
      nil
    end

    # ── selection ────────────────────────────────────────────────────────

    def selected_index : Int32
      return -1 if @order.empty?
      if call_id = @selected_call_id
        if index = @order.index(call_id)
          return index
        end
      end
      @order.size - 1
    end

    def selected_dialog : Dialog?
      index = selected_index
      return nil if index < 0
      @dialogs[@order[index]]?
    end

    def selected_message : Message?
      dialog = selected_dialog
      return nil unless dialog
      return nil if dialog.messages.empty?
      dialog.messages[@selected_message.clamp(0, dialog.messages.size - 1)]?
    end

    private def select_index(index : Int32)
      return if @order.empty?
      @selected_call_id = @order[index.clamp(0, @order.size - 1)]
    end

    # Returns false when the view is done and the monitor should go back to the
    # node frame. Anything it does not know is ignored, never an error.
    def handle_key(key : String) : Bool
      case @mode
      when .list?
        case key
        when "up", "k"   then select_index(selected_index - 1)
        when "down", "j" then select_index(selected_index + 1)
        when "g"         then select_index(0)
        when "G"         then select_index(@order.size - 1)
        when "\r", "\n"
          if dialog = selected_dialog
            @selected_call_id = dialog.call_id
            @mode = Mode::Flow
            # Open on the newest message, the way the list opens on the newest
            # dialog.
            @selected_message = {dialog.messages.size - 1, 0}.max
            @flow_top = 0
          end
        when "q", "esc" then return false
        end
      when .flow?
        dialog = selected_dialog
        size = dialog ? dialog.messages.size : 0
        last = {size - 1, 0}.max
        case key
        when "up", "k"              then @selected_message = (@selected_message - 1).clamp(0, last)
        when "down", "j"            then @selected_message = (@selected_message + 1).clamp(0, last)
        when "g"                    then @selected_message = 0
        when "G"                    then @selected_message = last
        when "\r", "\n", "esc", "q" then @mode = Mode::List
        end
      end
      true
    end

    def hint : String
      case @mode
      when .flow? then "↑↓/jk message · ⏎/esc list · q back"
      else             "↑↓/jk select · ⏎ flow · q/esc back"
      end
    end

    # ── the frame ────────────────────────────────────────────────────────

    # Body lines only; the monitor owns the title bar and the footer.
    def frame(cols : Int32, rows : Int32, now : Time = Time.utc) : Array(String)
      cols = 40 if cols < 40
      rows = 4 if rows < 4
      case @mode
      when .flow? then flow_frame(cols, rows, now)
      else             list_frame(cols, rows, now)
      end
    end

    # ── list ─────────────────────────────────────────────────────────────

    private def list_frame(cols : Int32, rows : Int32, now : Time) : Array(String)
      lines = [] of String
      # Fixed columns first; the Call-ID takes whatever is left, because it is
      # the only field with no natural width.
      party = cols >= 100 ? 20 : 13
      # 8, because REGISTER is eight characters and a truncated one reads as a
      # different method.
      fixed = 2 + 8 + 1 + 8 + 1 + party + 1 + party + 1 + 10 + 1 + 4 + 1 + 4 + 2
      call_w = (cols - fixed).clamp(0, 44)
      header = "  #{"time".ljust(8)} #{"method".ljust(8)} #{"from".ljust(party)} #{"to".ljust(party)} " +
               "#{"last".ljust(10)} #{"msgs".ljust(4)} #{"age".ljust(4)}#{call_w > 0 ? "  call-id" : ""}"
      lines << Colors.dim(header)
      if @order.empty?
        lines << ""
        lines << "  #{Colors.dim(empty_note)}"
        return lines
      end
      body_rows = {rows - lines.size, 1}.max
      selected = selected_index
      @list_top = @list_top.clamp(0, {@order.size - body_rows, 0}.max)
      @list_top = selected if selected < @list_top
      @list_top = selected - body_rows + 1 if selected >= @list_top + body_rows
      @list_top = 0 if @list_top < 0
      @order[@list_top, body_rows].each_with_index do |call_id, offset|
        dialog = @dialogs[call_id]
        next unless dialog
        index = @list_top + offset
        marker = index == selected ? Colors.bold("▸") : " "
        time = dialog.first_seen.to_s("%H:%M:%S")
        method = Colors.red(fit(dialog.first_method, 8))
        last = dialog.last_response.empty? ? Colors.dim(fit("—", 10)) : response_color(fit(dialog.last_response, 10), dialog.last_response)
        row = "#{marker} #{time} #{method} #{fit(dialog.from, party)} #{fit(dialog.to, party)} " +
              "#{last} #{fit(dialog.messages.size.to_s, 4)} #{fit(self.class.age(now - dialog.first_seen), 4)}"
        row += "  #{Colors.dim(fit(call_id, call_w))}" if call_w > 0
        lines << (index == selected ? Colors.bold(row) : row)
      end
      lines
    end

    private def empty_note : String
      if message = @error
        return "capture is not running: #{message}"
      end
      "no SIP yet — nothing is crossing this node, or capture is paused (voipappz sbc hep status)"
    end

    # ── flow ─────────────────────────────────────────────────────────────

    private def flow_frame(cols : Int32, rows : Int32, now : Time) : Array(String)
      dialog = selected_dialog
      return list_frame(cols, rows, now) unless dialog
      lines = [] of String
      lines << "  #{Colors.bold(fit(dialog.call_id, {cols - 4, 20}.max))}"
      count = dialog.messages.size
      summary = "#{dialog.first_method} #{dialog.from} → #{dialog.to}   #{count} message#{count == 1 ? "" : "s"}"
      summary += "   (#{dialog.dropped} older dropped)" if dialog.dropped > 0
      lines << "  #{Colors.dim(fit(summary, {cols - 4, 20}.max))}"

      side = cols >= SIDE_PANE_AT
      ladder_w = side ? cols - SIDE_PANE_W - 3 : cols
      pane_w = side ? SIDE_PANE_W : cols - 4
      body_rows = {rows - lines.size, 4}.max
      # Stacked, the ladder takes what it needs and the pane gets the rest —
      # a short flow should not leave the headers cut off under empty rows.
      ladder = ladder_lines(dialog, ladder_w, side ? body_rows : {body_rows - 5, 4}.max)
      pane_height = side ? body_rows : {body_rows - ladder.size - 1, 2}.max
      pane = pane_lines(pane_w, pane_height)
      if side
        lines.concat(compose(ladder, pane, ladder_w))
      else
        lines.concat(ladder)
        lines << Colors.divider(cols)
        pane.each { |l| lines << "  #{l}" }
      end
      lines
    end

    # One arrow per message. Endpoints that do not fit are NOT silently
    # dropped: the columns shrink first, then the extras are named in a note
    # and their messages render as plain "src → dst LABEL" rows, so a narrow
    # terminal loses the drawing and never the message.
    private def ladder_lines(dialog : Dialog, cols : Int32, rows : Int32) : Array(String)
      lines = [] of String
      endpoints = dialog.endpoints
      return ["  #{Colors.dim("no endpoints yet")}"] if endpoints.empty?
      gutter = 22
      available = {cols - gutter - 1, MIN_COLUMN}.max
      col_w = (available // endpoints.size).clamp(MIN_COLUMN, MAX_COLUMN)
      capacity = {available // col_w, 1}.max
      shown = endpoints[0, capacity]
      hidden = endpoints.size - shown.size
      width = col_w * shown.size

      heading = String.build do |io|
        shown.each { |ep| io << center(short_endpoint(ep, col_w - 1), col_w) }
      end
      lines << "#{" " * gutter}#{Colors.bold(heading)}"
      lines << "#{" " * gutter}#{Colors.dim(shown.map { |_| center("│", col_w) }.join)}"
      lines << "  #{Colors.dim("+#{hidden} more endpoint(s) off screen — their messages print as text")}" if hidden > 0

      body = {rows - lines.size, 1}.max
      selected = @selected_message.clamp(0, {dialog.messages.size - 1, 0}.max)
      @flow_top = @flow_top.clamp(0, {dialog.messages.size - body, 0}.max)
      @flow_top = selected if selected < @flow_top
      @flow_top = selected - body + 1 if selected >= @flow_top + body
      @flow_top = 0 if @flow_top < 0

      dialog.messages[@flow_top, body].each_with_index do |message, offset|
        index = @flow_top + offset
        previous = index > 0 ? dialog.messages[index - 1] : nil
        marker = index == selected ? Colors.bold("▸") : " "
        time = self.class.clock(message.line.ts)
        delta = previous ? self.class.delta(message.at - previous.at) : ""
        left = "#{marker} #{time.ljust(12)} #{Colors.dim(delta.ljust(6))} "
        lines << "#{left}#{arrow_row(message.line, shown, col_w, width)}"
      end
      lines
    end

    private def arrow_row(line : VoIPAppz::NodeCapture::Line, shown : Array(String), col_w : Int32, width : Int32) : String
      label = fit_label(line.label)
      from = shown.index(line.src)
      to = shown.index(line.dst)
      # Either end off screen: say it in words rather than draw a lie.
      if from.nil? || to.nil?
        return paint(line, fit("#{line.src} → #{line.dst}  #{label}", width))
      end
      row = Array(Char).new(width, ' ')
      shown.each_index { |i| row[i * col_w + col_w // 2] = '│' }
      a = from * col_w + col_w // 2
      b = to * col_w + col_w // 2
      if a == b
        # A message a box sent to itself: no span to draw, just mark the column.
        row[a] = '↻'
        place(row, label, {a + 2, width - label.size}.min)
        return paint(line, row.join)
      end
      lo, hi = a < b ? {a, b} : {b, a}
      (lo..hi).each { |i| row[i] = '─' }
      row[b] = b > a ? '▶' : '◀'
      if label.size <= hi - lo - 1
        start = lo + (hi - lo + 1 - label.size) // 2
        start = lo + 1 if start <= lo
        place(row, label, start)
      else
        # No room between the columns — hang the label off the right edge if
        # there is any, otherwise let it be cut at the edge.
        place(row, label, {hi + 2, {width - label.size, 0}.max}.min)
      end
      paint(line, row.join)
    end

    private def place(row : Array(Char), text : String, at : Int32)
      return if at < 0
      text.each_char_with_index do |char, i|
        index = at + i
        row[index] = char if index >= 0 && index < row.size
      end
    end

    private def fit_label(label : String) : String
      label.size > 16 ? label[0, 16] : label
    end

    # sngrep's convention: a REQUEST is red, a REPLY is green. A failure reply
    # is yellow so it still separates from both — the code in the label says
    # which, the colour says how to feel about it.
    private def paint(line : VoIPAppz::NodeCapture::Line, text : String) : String
      return Colors.red(text) if line.request?
      code = line.status.to_i? || 0
      return Colors.yellow(text) if code >= 400
      Colors.green(text)
    end

    private def response_color(text : String, label : String) : String
      code = label.split(' ').first?.try(&.to_i?) || 0
      code >= 400 ? Colors.yellow(text) : Colors.green(text)
    end

    # ── the message pane ─────────────────────────────────────────────────

    private def pane_lines(width : Int32, rows : Int32) : Array(String)
      width = 20 if width < 20
      message = selected_message
      return [Colors.dim("no message selected")] unless message
      start_line, pairs, body = self.class.parse_message(message.line.raw)
      lines = [] of String
      lines << Colors.bold(fit(start_line.empty? ? message.line.label : start_line, width))
      lines << Colors.dim(fit("#{message.line.src} → #{message.line.dst}  #{message.line.proto}", width))
      lines << ""
      shown = 0
      HEADERS.each do |name|
        pairs.each do |pair|
          next unless pair[0] == name
          shown += 1
          wrap("#{name}: ", pair[1], width).each { |l| lines << l }
        end
      end
      extra = pairs.size - shown
      lines << Colors.dim("+#{extra} more header(s)") if extra > 0
      unless body.strip.empty?
        lines << ""
        lines << Colors.dim("body (#{body.bytesize} bytes)")
        body.gsub("\r\n", "\n").split('\n').each do |l|
          lines << fit(l.chomp('\r'), width) unless l.strip.empty?
        end
      end
      lines = lines[0, rows] if lines.size > rows
      lines
    end

    private def wrap(prefix : String, value : String, width : Int32) : Array(String)
      lines = [] of String
      room = {width - prefix.size, 8}.max
      remaining = value
      first = true
      while remaining.size > room
        lines << "#{first ? Colors.cyan(prefix) : " " * prefix.size}#{remaining[0, room]}"
        remaining = remaining[room..]
        first = false
      end
      lines << "#{first ? Colors.cyan(prefix) : " " * prefix.size}#{remaining}"
      lines
    end

    # Start line, headers in wire order (compact forms expanded, folded lines
    # joined), and the body. Never raises: a truncated capture is normal.
    def self.parse_message(raw : String) : {String, Array({String, String}), String}
      pairs = [] of {String, String}
      return {"", pairs, ""} if raw.empty?
      normalized = raw.gsub("\r\n", "\n")
      head, _, body = normalized.partition("\n\n")
      lines = head.split('\n')
      start_line = lines.shift? || ""
      lines.each do |raw_line|
        next if raw_line.strip.empty?
        if (raw_line.starts_with?(' ') || raw_line.starts_with?('\t')) && !pairs.empty?
          folded = pairs.pop
          pairs << {folded[0], "#{folded[1]} #{raw_line.strip}"}
          next
        end
        name, colon, value = raw_line.partition(':')
        next if colon.empty?
        pairs << {canonical(name.strip), value.strip}
      end
      {start_line.strip, pairs, body}
    end

    def self.canonical(name : String) : String
      key = name.downcase
      COMPACT[key]? || CANON[key]? || key.split('-').map(&.capitalize).join('-')
    end

    # ── small shared shapes ──────────────────────────────────────────────

    # "hh:mm:ss.mmm" out of the node's RFC3339 timestamp, whatever it sends.
    def self.clock(ts : String) : String
      return ts if ts.size < 23
      ts[11, 12]
    end

    def self.delta(span : Time::Span) : String
      seconds = span.total_seconds
      return "+#{"%.1f" % seconds}" if seconds >= 100
      "+#{"%.3f" % seconds}"
    end

    # Four characters at most: this is a column, not a report.
    def self.age(span : Time::Span) : String
      seconds = span.total_seconds
      return "0s" if seconds < 0
      return "#{seconds.to_i}s" if seconds < 60
      return "#{(seconds / 60).to_i}m" if seconds < 3600
      "#{(seconds / 3600).to_i}h"
    end

    private def short_endpoint(endpoint : String, width : Int32) : String
      return endpoint if endpoint.size <= width
      # The port is the half that identifies a leg; keep it.
      host, colon, port = endpoint.rpartition(':')
      return endpoint[0, width] if colon.empty? || port.size + 2 > width
      "#{host[0, width - port.size - 2]}…:#{port}"
    end

    private def center(text : String, width : Int32) : String
      return text[0, width] if text.size >= width
      left = (width - text.size) // 2
      "#{" " * left}#{text}#{" " * (width - text.size - left)}"
    end

    private def fit(text : String, width : Int32) : String
      return "" if width <= 0
      return text.ljust(width) if text.size <= width
      return text[0, width] if width < 2
      "#{text[0, width - 1]}…"
    end

    # Two stacks of lines, side by side, padded by VISIBLE width so the ANSI in
    # them does not shove the pane sideways.
    private def compose(left : Array(String), right : Array(String), left_w : Int32) : Array(String)
      height = {left.size, right.size}.max
      (0...height).map do |i|
        l = left[i]? || ""
        r = right[i]? || ""
        pad = {left_w - self.class.visible_length(l), 0}.max
        "#{l}#{" " * pad} #{Colors.dim("│")} #{r}"
      end
    end

    def self.visible_length(text : String) : Int32
      text.gsub(/\e\[[0-9;]*m/, "").size
    end
  end
end
