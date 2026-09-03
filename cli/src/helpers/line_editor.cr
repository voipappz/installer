module VoIPAppz
  # Minimal dependency-free raw-mode line editor for the interactive console.
  # Claude-CLI-style ergonomics: arrow-key cursor + history, TAB completion,
  # Ctrl-C cancels the line (not the session), Ctrl-D on empty line exits,
  # persistent history file. Falls back to plain gets when STDIN isn't a TTY.
  class LineEditor
    HISTORY_MAX = 1000

    # completer(tokens_before_partial, partial) -> candidate completions
    alias Completer = Proc(Array(String), String, Array(String))
    # highlighter(line) -> ANSI-colored line for display (length-neutral:
    # cursor math counts glyphs, not escape codes, so coloring is safe)
    alias Highlighter = Proc(String, String)

    @history = [] of String
    property highlighter : Highlighter = ->(line : String) { line }

    def initialize(@history_file : String, @completer : Completer)
      begin
        if File.exists?(@history_file)
          @history = File.read_lines(@history_file).last(HISTORY_MAX)
        end
      rescue
        @history = [] of String
      end
    end

    # Returns the line, "" when cancelled (Ctrl-C), nil on EOF (Ctrl-D/closed).
    def read_line(prompt : String) : String?
      return gets_fallback(prompt) unless STDIN.tty?

      buf = [] of Char
      pos = 0
      hist_idx = @history.size
      stash = "" # in-progress line stashed while browsing history

      STDIN.raw do
        redraw(prompt, buf, pos)
        loop do
          ch = STDIN.read_char
          case ch
          when nil
            print "\r\n"
            return nil
          when '\r', '\n'
            print "\r\n"
            line = buf.join
            remember(line)
            return line
          when '\u{3}' # Ctrl-C — cancel the line, keep the console
            print "^C\r\n"
            return ""
          when '\u{4}' # Ctrl-D — EOF on empty line, else delete-at-cursor
            if buf.empty?
              print "\r\n"
              return nil
            elsif pos < buf.size
              buf.delete_at(pos)
            end
          when '\u{1}' then pos = 0        # Ctrl-A
          when '\u{5}' then pos = buf.size # Ctrl-E
          when '\u{15}'                    # Ctrl-U — kill to start
            buf = buf[pos..]
            pos = 0
          when '\u{17}' # Ctrl-W — delete word before cursor
            while pos > 0 && buf[pos - 1] == ' '
              buf.delete_at(pos - 1); pos -= 1
            end
            while pos > 0 && buf[pos - 1] != ' '
              buf.delete_at(pos - 1); pos -= 1
            end
          when '\u{c}' # Ctrl-L — clear screen
            print "\e[2J\e[H"
          when '\t'
            complete(prompt, buf, pos).try { |r| buf = r; pos = buf.size }
          when '\u{7f}', '\b'
            if pos > 0
              buf.delete_at(pos - 1)
              pos -= 1
            end
          when '\e'
            seq = read_csi
            case seq
            when "[A" # up — older history
              if hist_idx > 0
                stash = buf.join if hist_idx == @history.size
                hist_idx -= 1
                buf = @history[hist_idx].chars
                pos = buf.size
              end
            when "[B" # down — newer history
              if hist_idx < @history.size
                hist_idx += 1
                buf = (hist_idx == @history.size ? stash : @history[hist_idx]).chars
                pos = buf.size
              end
            when "[C" then pos += 1 if pos < buf.size # right
            when "[D" then pos -= 1 if pos > 0        # left
            when "[H", "[1~" then pos = 0             # home
            when "[F", "[4~" then pos = buf.size      # end
            when "[3~" # delete
              buf.delete_at(pos) if pos < buf.size
            end
          else
            if ch && !ch.control?
              buf.insert(pos, ch)
              pos += 1
            end
          end
          redraw(prompt, buf, pos)
        end
      end
    end

    private def gets_fallback(prompt : String) : String?
      line = gets
      return nil if line.nil?
      line.chomp
    end

    private def remember(line : String)
      line = line.strip
      return if line.empty? || @history.last? == line
      @history << line
      @history = @history.last(HISTORY_MAX)
      File.write(@history_file, @history.join("\n") + "\n") rescue nil
    end

    # Read the remainder of a CSI escape sequence ("[" + params + final byte).
    private def read_csi : String
      first = STDIN.read_char
      return "" unless first == '['
      seq = String.build do |io|
        io << '['
        while ch = STDIN.read_char
          io << ch
          break unless ch.ascii_number? || ch == ';'
        end
      end
      seq
    end

    # TAB completion on the last token (cursor must be at end of line).
    # Returns the new buffer, or nil when nothing changed.
    private def complete(prompt : String, buf : Array(Char), pos : Int32) : Array(Char)?
      return nil unless pos == buf.size
      line = buf.join
      return nil if line.starts_with?('!')

      head, _, partial = line.rpartition(' ')
      tokens = head.split(' ', remove_empty: true)
      candidates = @completer.call(tokens, partial).select(&.starts_with?(partial)).sort!
      return nil if candidates.empty?

      if candidates.size == 1
        return (head.empty? ? "" : head + " ").chars + (candidates[0] + " ").chars
      end

      # Extend to the longest common prefix; if stuck, list the options.
      common = candidates.reduce(candidates[0]) do |acc, cand|
        n = 0
        while n < acc.size && n < cand.size && acc[n] == cand[n]
          n += 1
        end
        acc[0, n]
      end
      if common.size > partial.size
        return (head.empty? ? "" : head + " ").chars + common.chars
      end
      print "\r\n" + candidates.join("  ") + "\r\n"
      redraw(prompt, buf, pos)
      nil
    end

    private def redraw(prompt : String, buf : Array(Char), pos : Int32)
      print "\r\e[K", prompt, @highlighter.call(buf.join)
      back = buf.size - pos
      print "\e[#{back}D" if back > 0
      STDOUT.flush
    end
  end
end
