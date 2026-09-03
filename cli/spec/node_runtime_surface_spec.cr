require "./spec_helper"

# The image's command boundary is compile-time, so inspecting constants in the
# normal development spec binary would only prove the unflagged half. Compile
# and execute the same entry point with the image flag: this catches a command
# that remains in Admiral help as well as one left in the console's validation
# catalog.
describe "node-runtime CLI surface" do
  it "compiles a production CLI that exposes only in-image operations" do
    binary = File.tempname("voipappz-node-runtime")
    build_error = IO::Memory.new

    begin
      # --no-debug because this binary is only ever asked for --help. Debug
      # info is the memory hog, and compiling a SECOND full binary inside a
      # spec run that already holds one has been killed by the OOM killer
      # (exit 137, an empty stderr, and a failure that reads like a code
      # error). Nothing here inspects a stack trace.
      build = Process.run(
        "crystal",
        ["build", "src/voipappz.cr", "-D", "node_runtime", "--no-debug", "-o", binary],
        output: Process::Redirect::Close,
        error: build_error
      )
      # 137 is SIGKILL — out of memory, not a broken tree. Say which it was:
      # the bare `should be_true` reported a compile failure with no stderr to
      # explain it, and sent everyone reading it looking for a syntax error.
      unless build.success?
        detail = build_error.to_s.strip
        detail = "killed (exit 137) — out of memory, not a compile error" if build.exit_code == 137 && detail.empty?
        fail "the -Dnode_runtime build failed: #{detail}"
      end

      help = IO::Memory.new
      help_error = IO::Memory.new
      help_status = Process.run(binary, ["--help"], output: help, error: help_error)
      help_status.success?.should be_true, help_error.to_s

      text = help.to_s
      # Hand-maintained, and its twin lives in ANOTHER repo now
      # (va-crystal scripts/assert-runtime-image.sh), so a command added to one
      # and forgotten in the other is a real risk. Anything registered outside
      # `{% unless flag?(:node_runtime) %}` in src/voipappz.cr belongs here.
      forbidden = %w(
        up down restart status bootstrap login secrets config logs shell
        checks test app portal deploy cert backup db clean syslog trace security mcp
      )
      forbidden.each do |command|
        text.should_not match(/^\s+#{command}\b/m)

        command_output = IO::Memory.new
        command_error = IO::Memory.new
        status = Process.run(binary, [command, "--help"], output: command_output, error: command_error)
        status.exit_code.should eq(2)
        command_error.to_s.should contain("unknown command `#{command}`")
      end

      # `monitor` is the in-container NodeMonitor (health + capture), not the
      # docker-plane Monitor — same name, the node's own answers as the source.
      %w(setup node sync dump env console health switch nats sbc pbx monitor).each do |command|
        text.should match(/^\s+#{command}\b/m)
      end

      sbc_help = IO::Memory.new
      Process.run(binary, ["sbc", "--help"], output: sbc_help, error: Process::Redirect::Close)
        .success?.should be_true
      sbc_help.to_s.should match(/^\s+egress\b/m)
      sbc_help.to_s.should_not match(/^\s+ingress\b/m)

      hep_help = IO::Memory.new
      Process.run(binary, ["sbc", "hep", "--help"], output: hep_help, error: Process::Redirect::Close).success?.should be_true
      %w(status enable disable tail query).each { |sub| hep_help.to_s.should match(/^\s+#{sub}\b/m) }

      db_help = IO::Memory.new
      Process.run(binary, ["sbc", "egress", "db", "--help"],
        output: db_help, error: Process::Redirect::Close).success?.should be_true
      db_help.to_s.should match(/^\s+status\b/m)
      db_help.to_s.should_not match(/^\s+init\b/m)

      direct_error = IO::Memory.new
      Process.run(binary, ["health", "--direct"],
        output: Process::Redirect::Close, error: direct_error).exit_code.should eq(2)
      direct_error.to_s.should contain("requires the host development stack")
    ensure
      File.delete(binary) if File.exists?(binary)
    end
  end
end
