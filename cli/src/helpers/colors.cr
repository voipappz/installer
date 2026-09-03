module VoIPAppz::Colors
  # ANSI escapes are emitted only when output is going to a terminal AND
  # the operator hasn't asked for plain text. Set VOIPAPPZ_JSON=1 (the
  # `--json` flag does this) or NO_COLOR=1 to force plain output.
  def self.enabled? : Bool
    return false if ENV["NO_COLOR"]?
    return false if ENV["VOIPAPPZ_JSON"]? == "1"
    STDOUT.tty?
  end

  private def self.wrap(code : String, text : String) : String
    enabled? ? "#{code}#{text}#{RESET}" : text
  end

  RESET   = "\e[0m"
  BOLD    = "\e[1m"
  DIM     = "\e[2m"
  UNDERLINE = "\e[4m"
  GREEN   = "\e[32m"
  RED     = "\e[31m"
  YELLOW  = "\e[33m"
  BLUE    = "\e[34m"
  PURPLE  = "\e[35m"
  CYAN    = "\e[36m"
  WHITE   = "\e[37m"
  BG_GREEN = "\e[42m"
  BG_RED   = "\e[41m"

  # Unicode icons
  CHECK  = "\u2714"  # ✔
  CROSS  = "\u2718"  # ✘
  WARN   = "\u26A0"  # ⚠
  ARROW  = "\u279C"  # ➜
  BULLET = "\u25CF"  # ●
  STAR   = "\u2605"  # ★
  HEART  = "\u2665"  # ♥
  BOLT   = "\u26A1"  # ⚡

  # Emoji icons
  LOCK    = "\u{1F512}"  # 🔒
  UNLOCK  = "\u{1F513}"  # 🔓
  KEY     = "\u{1F511}"  # 🔑
  GEAR    = "\u2699"      # ⚙
  ROCKET  = "\u{1F680}"  # 🚀
  DB      = "\u{1F5C4}"  # 🗄
  NET     = "\u{1F310}"  # 🌐
  CLOCK   = "\u23F1"      # ⏱
  SHIELD  = "\u{1F6E1}"  # 🛡
  BOX     = "\u{1F4E6}"  # 📦
  PHONE   = "\u260E"      # ☎

  def self.green(text : String) : String
    wrap(GREEN, text)
  end

  def self.red(text : String) : String
    wrap(RED, text)
  end

  def self.yellow(text : String) : String
    wrap(YELLOW, text)
  end

  def self.blue(text : String) : String
    wrap(BLUE, text)
  end

  def self.cyan(text : String) : String
    wrap(CYAN, text)
  end

  def self.purple(text : String) : String
    wrap(PURPLE, text)
  end

  def self.bold(text : String) : String
    wrap(BOLD, text)
  end

  def self.dim(text : String) : String
    wrap(DIM, text)
  end

  def self.ok : String
    "#{GREEN}#{BOLD} #{CHECK}  OK #{RESET}"
  end

  def self.fail : String
    "#{RED}#{BOLD} #{CROSS} FAIL#{RESET}"
  end

  def self.warn : String
    "#{YELLOW}#{BOLD} #{WARN} WARN#{RESET}"
  end

  def self.dot_ok : String
    "#{GREEN}#{CHECK}#{RESET}"
  end

  def self.dot_fail : String
    "#{RED}#{CROSS}#{RESET}"
  end

  def self.dot_warn : String
    "#{YELLOW}#{WARN}#{RESET}"
  end

  # Semantic helpers

  def self.header(text : String, width : Int32 = 60) : String
    bar_len = width - text.size - 4
    bar_len = 4 if bar_len < 4
    "#{BOLD}#{CYAN}\u2501\u2501 #{text} #{"\u2501" * bar_len}#{RESET}"
  end

  def self.step(n : Int32, text : String) : String
    "  #{CYAN}#{ARROW} [#{n}]#{RESET} #{text}"
  end

  def self.success(text : String) : String
    "  #{GREEN}#{CHECK}#{RESET} #{text}"
  end

  def self.error(text : String) : String
    "  #{RED}#{CROSS}#{RESET} #{text}"
  end

  def self.warning(text : String) : String
    "  #{YELLOW}#{WARN}#{RESET}  #{text}"
  end

  def self.info(text : String) : String
    "  #{BLUE}#{BULLET}#{RESET} #{text}"
  end

  def self.banner(lines : Array(String), width : Int32 = 60) : String
    inner = width - 4
    result = String.build do |io|
      io << CYAN << BOLD
      io << "\u2554" << "\u2550" * (width - 2) << "\u2557" << "\n"
      lines.each do |line|
        padding = inner - visible_length(line)
        padding = 0 if padding < 0
        io << "\u2551 " << line << " " * (padding + 1) << "\u2551" << "\n"
      end
      io << "\u255A" << "\u2550" * (width - 2) << "\u255D"
      io << RESET
    end
    result
  end

  def self.divider(width : Int32 = 60) : String
    "#{DIM}#{"\u2500" * width}#{RESET}"
  end

  def self.progress_bar(current : Int32, total : Int32, width : Int32 = 30) : String
    return "[#{"?" * width}] #{current}/#{total}" if total == 0
    filled = (current * width) // total
    filled = width if filled > width
    empty = width - filled
    "#{CYAN}[#{GREEN}#{"\u2588" * filled}#{DIM}#{"\u2591" * empty}#{RESET}#{CYAN}]#{RESET} #{current}/#{total}"
  end

  # Calculate visible length of a string (excluding ANSI escape codes)
  private def self.visible_length(text : String) : Int32
    text.gsub(/\e\[[0-9;]*m/, "").size
  end
end
