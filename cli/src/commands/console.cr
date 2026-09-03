require "admiral"
require "../helpers/colors"
require "../helpers/line_editor"

module VoIPAppz
  # How a child process ENDED, in words.
  #
  # `Process::Status#exit_code` RAISES on a process that was signalled — there
  # is no exit code to report — and Ctrl+C is the ordinary way to stop `logs`
  # or `monitor`. Reading it unguarded turned that into
  # "failed to run: Abnormal exit has no exit code", which reads as a broken
  # console rather than the user's own interrupt.
  module Console
    def self.outcome(status : Process::Status) : String
      return "exit #{status.exit_code}" if status.normal_exit?
      signal = status.exit_signal
      signal == Signal::INT ? "interrupted" : "killed (#{signal})"
    end
  end
end

module VoIPAppz::Commands
  # Interactive operator console (REPL). Claude-CLI-style: native line editing
  # (arrow-key history, TAB completion, Ctrl-C cancels the line), persistent
  # history, '!' shell escape, and a `watch` mode for live-refreshing views.
  # Each line dispatches as a voipappz subcommand by re-invoking this same
  # binary — commands render their own tables/logs inline and run isolated
  # (a failing command can't take the console down).
  #
  # Evaluated and rejected: crystal-community/icr — a Crystal *language* REPL
  # that needs the compiler on the host and re-runs the whole session per line.
  # Full-screen TUI rejected for now: it would mean re-rendering every command
  # as widgets; `watch` gives the live-dashboard moment without a rewrite.
  class Console < Admiral::Command
    define_help description: "Interactive console — REPL with history, TAB completion, watch mode"

    # A curated map keeps discovery useful without dumping an alphabetical wall
    # of implementation details on developers. Every public CLI command appears
    # exactly once; console-only actions live in BUILTINS.
    COMMAND_GROUPS = {% if flag?(:node_runtime) %}
                       [
                         {"Operate", %w(health monitor)},
                         {"Voice", %w(sbc pbx switch)},
                         {"Configure", %w(setup node sync env)},
                         {"Advanced", %w(dump nats)},
                       ]
                     {% else %}
                       [
                         {"Operate", %w(status health up down restart logs monitor shell)},
                         {"Voice", %w(sbc pbx trace test switch)},
                         {"Configure", %w(setup node sync config env secrets cert)},
                         # `image` is NOT here: it was deleted when image
                         # building became `make image` (next-cli-boundary.md
                         # step 3), but the catalog entry stayed — and since the
                         # unknown-command guard is driven by this list, and
                         # nothing registers an Image class, `voipappz image`
                         # passed the guard, printed root help and exited 0.
                         # A typo that reports success is the exact failure the
                         # guard exists to prevent. An entry here without a
                         # matching register_sub_command is always that bug.
                         #
                         # AND THE MIRROR IMAGE, hit while moving a command in
                         # on 2026-09-01: a registered command missing from this
                         # list is advertised by `--help` and then REJECTED by
                         # the guard as unknown. Both directions have to be kept
                         # by hand. Only this one is cheap to notice — it fails
                         # on the first run; the other exits 0.
                         {"Build & ship", %w(checks app portal deploy backup db clean)},
                         {"Advanced", %w(bootstrap login dump syslog nats security mcp)},
                       ]
                     {% end %}
    CLI_COMMANDS   = COMMAND_GROUPS.flat_map(&.[1])
    ROOT_COMMANDS  = CLI_COMMANDS + ["console"]
    BUILTINS       = %w(help watch clear version exit quit q)
    QUICK_COMMANDS = {% if flag?(:node_runtime) %}
                       {
                         "s" => %w(health),
                         "h" => %w(help),
                       }
                     {% else %}
                       {
                         "s" => %w(health),
                         "c" => %w(status --active),
                         "l" => %w(logs),
                         "h" => %w(help),
                       }
                     {% end %}
    EVERYDAY_COMMANDS = {% if flag?(:node_runtime) %}
                          %w(health sbc pbx setup)
                        {% else %}
                          %w(status up down logs sbc pbx test deploy)
                        {% end %}
    # Bare TAB stays intentionally small. `help` and `help <TAB>` expose the
    # complete catalog, while every command remains directly invokable.
    TOP_COMMANDS   = EVERYDAY_COMMANDS + %w(help)
    INPUT_COMMANDS = ROOT_COMMANDS + BUILTINS + QUICK_COMMANDS.keys

    # Old paths get a direct migration hint instead of silently printing the
    # root help, which made a typo look like a successful command.
    MOVED_COMMANDS = {% if flag?(:node_runtime) %}
                       {"egress" => "sbc", "ingress" => "sbc"}
                     {% else %}
                       {
                         "ingress" => "sbc ingress",
                         "egress"  => "sbc egress",
                         "hep"     => "trace hep",
                       }
                     {% end %}

    # Nested completion vocabulary for operational command paths.
    NESTED = begin
      nested = {
        ["node"]                        => %w(register install),
        ["nats"]                        => %w(request),
        ["pbx"]                         => %w(cli shell status),
        ["switch"]                      => %w(logs),
        ["switch", "logs"]              => %w(--follow --grep --level --exchange --raw),
      }
      # The completion catalog must follow sip.cr's shape exactly: a node has ONE
      # kamailio and no ingress/egress level, the host build has both boxes.
      {% if flag?(:node_runtime) %}
        nested[["sbc"]]               = %w(status list sync reload shell dispatcher address domain subscriber trace db hep)
        nested[["sbc", "list"]]       = %w(dispatcher address domain all)
        nested[["sbc", "address"]]    = %w(add remove)
        nested[["sbc", "dispatcher"]] = %w(status add rm)
        nested[["sbc", "domain"]]     = %w(add)
        nested[["sbc", "subscriber"]] = %w(add remove passwd show)
        nested[["sbc", "trace"]]      = %w(on off status query)
        nested[["sbc", "db"]]         = %w(status)
        nested[["sbc", "hep"]]        = %w(enable disable status tail query)
      {% end %}
      {% unless flag?(:node_runtime) %}
        nested[["sbc"]]                         = %w(ingress egress hep)
        nested[["sbc", "egress"]]               = %w(sync status list reload shell dispatcher address domain subscriber trace db)
        nested[["sbc", "egress", "list"]]       = %w(dispatcher address domain all)
        nested[["sbc", "egress", "address"]]    = %w(add remove)
        nested[["sbc", "egress", "dispatcher"]] = %w(status add rm)
        nested[["sbc", "egress", "domain"]]     = %w(add)
        nested[["sbc", "egress", "subscriber"]] = %w(add remove passwd show)
        nested[["sbc", "egress", "trace"]]      = %w(on off status query)
        nested[["sbc", "egress", "db"]]         = %w(init status)
        nested[["sbc", "ingress"]] = %w(sync list reload status shell)
        nested[["trace"]] = %w(hep)
        nested[["trace", "hep"]] = %w(enable disable status listen send selftest query)
        nested[["logs"]] = %w(--profile --service)
        nested[["test"]] = %w(scenario --level --calls --duration --target --port --user --password --domain)
        nested[["test", "scenario"]] = %w(--out --compile-only --dry-run --destination --source --to --calls --cps --concurrent --docker --image)
        nested[["up"]] = %w(-p --profile --wait --recreate --service)
        nested[["portal"]] = %w(dev up down logs check verify status build lint unit test prod deploy ship token env scaffold ci)
        nested[["portal", "deploy"]] = %w(-d --dest --print --path)
        nested[["portal", "ship"]]   = %w(-d --dest --print --path)
        nested[["portal", "test"]]   = %w(--crystal)
        nested[["portal", "prod"]]   = %w(--down)
        nested[["portal", "token"]]  = %w(--show)
        nested[["portal", "ci"]]     = %w(--api)
      {% end %}
      nested
    end

    def self.completions(tokens : Array(String)) : Array(String)
      return TOP_COMMANDS if tokens.empty?

      path = tokens
      if path.first? == "help"
        path = path[1..]
      elsif path.first? == "watch"
        path = path[1..]
        path = path[2..] if path.first? == "-n" && path.size >= 2
      end

      return CLI_COMMANDS if path.empty?
      NESTED[path]? || [] of String
    end

    def self.command_guidance(args : Array(String)) : String?
      command = args.first?
      return nil unless command
      return nil if CLI_COMMANDS.includes?(command)

      suffix = args[1..].join(" ")
      if moved = MOVED_COMMANDS[command]?
        replacement = suffix.empty? ? moved : "#{moved} #{suffix}"
        return "`#{command}` moved — use `#{replacement}`"
      end

      suggestion = closest_command(command)
      if suggestion
        "unknown command `#{command}` — did you mean `#{suggestion}`?"
      else
        "unknown command `#{command}` — run `help` to see available commands"
      end
    end

    def self.render_help : String
      String.build do |io|
        io << VoIPAppz::Colors.header("Commands") << '\n'
        COMMAND_GROUPS.each do |name, commands|
          io << '\n' << VoIPAppz::Colors.bold(name) << '\n'
          io << "  " << commands.join("  ") << '\n'
        end
        io << '\n' << VoIPAppz::Colors.bold("Console") << '\n'
        io << "  help <command>  watch [-n seconds] <command>  clear  exit\n"
        io << '\n' << VoIPAppz::Colors.dim("TAB completes commands · prefix with ! to run a shell command")
      end
    end

    private def self.closest_command(input : String) : String?
      candidate = CLI_COMMANDS.min_by? { |command| edit_distance(input, command) }
      return nil unless candidate
      distance = edit_distance(input, candidate)
      distance <= {2, input.size // 3}.max ? candidate : nil
    end

    private def self.edit_distance(left : String, right : String) : Int32
      a = left.chars
      b = right.chars
      previous = (0..b.size).to_a

      a.each_with_index do |char, i|
        current = [i + 1]
        b.each_with_index do |other, j|
          insert = current[j] + 1
          delete = previous[j + 1] + 1
          replace = previous[j] + (char == other ? 0 : 1)
          current << {insert, delete, replace}.min
        end
        previous = current
      end
      previous.last
    end

    @watch_interrupted = false

    def run
      bin = Process.executable_path
      unless bin
        STDERR.puts VoIPAppz::Colors.red("cannot resolve own binary path")
        exit 1
      end

      # Survive Ctrl-C: the child command (same foreground group) still dies —
      # exactly what you want when interrupting `logs` or `watch` — but the
      # console itself keeps running and shows the prompt again.
      Signal::INT.trap { @watch_interrupted = true }

      interactive = STDIN.tty?
      if interactive
        # Opening on a bare prompt tells an operator nothing about the node
        # they just opened. The node build has no `status` — that is the
        # mothership's rollup — so it greets with its OWN verdict, which is
        # the same thing the image's HEALTHCHECK polls.
        {% if flag?(:node_runtime) %}
          run_sub(bin, ["health"], report: false)
        {% else %}
          run_sub(bin, ["status", "--bar", "--active"], report: false)
        {% end %}
        puts ""
        puts VoIPAppz::Colors.dim("TAB: everyday commands · help: all commands · Ctrl-C: cancel")
        {% if flag?(:node_runtime) %}
          puts VoIPAppz::Colors.dim("  Try `help`, `sbc status`, or `watch health`.")
        {% else %}
          puts VoIPAppz::Colors.dim("  Try `help`, `sbc ingress status`, or `watch status`.")
        {% end %}
        puts ""
      end

      editor = VoIPAppz::LineEditor.new(
        File.join(Path.home.to_s, ".voipappz_history"),
        ->(tokens : Array(String), _partial : String) { Console.completions(tokens) })
      # Live input highlight: first token green when it's a known command,
      # yellow while a known command still matches the prefix, red otherwise.
      editor.highlighter = ->(line : String) {
        cmd, sep, rest = line.partition(' ')
        colored = if cmd.empty?
                    cmd
                  elsif cmd.starts_with?('!') || INPUT_COMMANDS.includes?(cmd)
                    VoIPAppz::Colors.green(cmd)
                  elsif INPUT_COMMANDS.any?(&.starts_with?(cmd))
                    VoIPAppz::Colors.yellow(cmd)
                  else
                    VoIPAppz::Colors.red(cmd)
                  end
        colored + sep + rest
      }

      loop do
        line = editor.read_line(interactive ? VoIPAppz::Colors.bold("voipappz> ") : "")
        break if line.nil? # EOF
        line = line.strip
        next if line.empty? || line.starts_with?('#')

        case
        when {"exit", "quit", "q"}.includes?(line)
          break
        when {"help", "?", "h"}.includes?(line)
          puts Console.render_help
        when QUICK_COMMANDS.has_key?(line)
          run_sub(bin, QUICK_COMMANDS[line])
        when line.starts_with?("help ") || line.starts_with?("? ")
          spec = line.partition(' ')[2].strip
          args = parse_line(spec)
          next unless args
          if guidance = Console.command_guidance(args)
            STDERR.puts VoIPAppz::Colors.yellow(guidance)
          else
            run_sub(bin, args + ["--help"])
          end
        when line == "clear"
          print "\e[2J\e[H"
        when line == "version"
          run_sub(bin, ["--version"])
        when line.starts_with?('!')
          sh = line[1..].strip
          next if sh.empty?
          st = Process.run(sh, shell: true,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit)
          puts VoIPAppz::Colors.dim("(#{VoIPAppz::Console.outcome(st)})") unless st.success?
        when line.starts_with?("watch ")
          run_watch(bin, line.lchop("watch ").strip)
        else
          args = parse_line(line)
          next unless args
          args.shift if args.first?.try { |a| a == "voipappz" || a.ends_with?("/voipappz") }
          next if args.empty?
          if guidance = Console.command_guidance(args)
            STDERR.puts VoIPAppz::Colors.yellow(guidance)
          else
            run_sub(bin, args)
          end
        end
      end

      puts VoIPAppz::Colors.dim("bye") if interactive
    end

    private def parse_line(line : String) : Array(String)?
      Process.parse_arguments(line)
    rescue ex
      STDERR.puts VoIPAppz::Colors.red("could not parse command: #{ex.message}")
      nil
    end

    private def run_sub(bin : String, args : Array(String), report : Bool = true)
      started = Time.monotonic
      status = Process.run(bin, args,
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)
      elapsed = Time.monotonic - started
      if !status.success?
        puts VoIPAppz::Colors.red(VoIPAppz::Console.outcome(status)) if report
      elsif report && elapsed >= 1.second
        puts VoIPAppz::Colors.dim("#{VoIPAppz::Colors::CHECK} done in #{elapsed.total_seconds.round(1)}s")
      end
    rescue ex
      STDERR.puts VoIPAppz::Colors.red("failed to run: #{ex.message}")
    end

    # TUI moment without a TUI: clear + re-run the command on an interval
    # until Ctrl-C. `watch status`, `watch -n 5 sbc egress dispatcher status`, …
    private def run_watch(bin : String, spec : String)
      interval = 2.0
      args = Process.parse_arguments(spec)
      if args.size >= 2 && args[0] == "-n"
        interval = args[1].to_f? || 2.0
        args = args[2..]
      end
      return if args.empty?

      @watch_interrupted = false
      loop do
        print "\e[2J\e[H"
        puts VoIPAppz::Colors.dim("watch -n #{interval} #{args.join(" ")} — #{Time.local} — Ctrl-C to stop")
        run_sub(bin, args, report: false)
        # Sleep in small slices so Ctrl-C reacts quickly.
        slept = 0.0
        while slept < interval && !@watch_interrupted
          sleep 0.2.seconds
          slept += 0.2
        end
        break if @watch_interrupted
      end
      puts VoIPAppz::Colors.dim("\n(watch stopped)")
    end
  end
end
