require "./spec_helper"
require "../src/commands/console"

# The SIP plane has one `sbc` namespace and an explicit direction for every
# box-specific operation. SQLite-backed operations belong to the egress alone.
#
# The console's completion vocabulary is the CLI's own map of its surface, so
# asserting on it is how a re-introduced duplicate gets caught here rather than
# on a node.
describe "command surface" do
  top = VoIPAppz::Commands::Console::ROOT_COMMANDS
  visible = VoIPAppz::Commands::Console::TOP_COMMANDS
  nested = VoIPAppz::Commands::Console::NESTED

  # Operations that read or write the kamailio SQLite database. The ingress
  # loads neither db_sqlite nor permissions, so aiming any of these at it is a
  # bug by construction, not a runtime accident.
  sqlite_groups = %w(dispatcher address domain subscriber trace db)

  it "groups both directional boxes under `sbc`" do
    top.should contain "sbc"
    top.should_not contain "ingress"
    top.should_not contain "egress"
    %w(ingress egress).each { |c| nested[["sbc"]].should contain c }
    top.should contain "pbx"
    top.should contain "trace"
  end

  it "exposes the local YAML dump command" do
    top.should contain "dump"
  end

  it "keeps console discovery aligned with the real CLI" do
    top.should contain "node"
    {% if flag?(:node_runtime) %}
      top.sort.should eq(%w(health sbc pbx switch setup node sync env dump nats console).sort)
    {% else %}
      %w(app db mcp).each { |command| top.should contain command }
    {% end %}
    top.should_not contain "sim"
  end

  it "keeps bare TAB focused on everyday work" do
    {% if flag?(:node_runtime) %}
      visible.should eq(%w(health sbc pbx setup help))
    {% else %}
      visible.should eq(%w(status up down logs sbc pbx test deploy help))
    {% end %}
    %w(trace setup node watch nats mcp bootstrap secrets).each do |command|
      visible.should_not contain command
    end
    VoIPAppz::Commands::Console.completions(["help"]).should contain("nats")
    VoIPAppz::Commands::Console.completions(["help"]).should contain("trace")
  end

  it "exposes node install and registration under the node namespace" do
    nested[["node"]].should eq(%w(register install))
  end

  it "provides real top-bar shortcuts without adding them to TAB" do
    {% if flag?(:node_runtime) %}
      VoIPAppz::Commands::Console::QUICK_COMMANDS.should eq({
        "s" => %w(health), "l" => %w(logs), "h" => %w(help),
      })
    {% else %}
      VoIPAppz::Commands::Console::QUICK_COMMANDS.should eq({
        "s" => %w(health), "c" => %w(status --active), "l" => %w(logs), "h" => %w(help),
      })
    {% end %}
    %w(s c l h q).each { |key| visible.should_not contain key }
  end

  {% if flag?(:node_runtime) %}
    it "does not advertise host lifecycle commands in a node runtime" do
      %w(up down restart status).each { |command| top.should_not contain command }
      nested.has_key?(["up"]).should be_false
    end
  {% else %}
    it "retains host lifecycle commands in a development build" do
      %w(up down restart status).each { |command| top.should contain command }
      nested[["up"]].should contain("--profile")
    end
  {% end %}

  it "completes command paths through help and watch" do
    # A node has ONE kamailio, so its commands hang off `sbc` directly and the
    # completion catalog must say so. `sbc egress ...` still RESOLVES there —
    # installed nodes run it — but it is deliberately not offered: the
    # flattened names are the ones to learn. See cli/src/commands/sip.cr.
    {% if flag?(:node_runtime) %}
      VoIPAppz::Commands::Console.completions(["help", "sbc"])
        .should eq(%w(status list sync reload shell dispatcher address domain subscriber trace db hep))
      VoIPAppz::Commands::Console.completions(["watch", "sbc"])
        .should contain("status")
    {% else %}
      VoIPAppz::Commands::Console.completions(["help", "sbc"])
        .should eq(%w(ingress egress hep))
      VoIPAppz::Commands::Console.completions(["watch", "sbc", "egress"])
        .should contain("status")
    {% end %}
    {% if flag?(:node_runtime) %}
      VoIPAppz::Commands::Console.completions(["watch", "-n", "5"])
        .should contain("health")
    {% else %}
      VoIPAppz::Commands::Console.completions(["watch", "-n", "5"])
        .should contain("status")
    {% end %}
  end

  it "guides old paths and command typos" do
    VoIPAppz::Commands::Console.command_guidance(%w(egress status))
      .should eq({% if flag?(:node_runtime) %} "`egress` moved — use `sbc status`" \
                 {% else %} "`egress` moved — use `sbc egress status`" {% end %})
    VoIPAppz::Commands::Console.command_guidance(%w(healt))
      .should eq("unknown command `healt` — did you mean `health`?")
    {% if flag?(:node_runtime) %}
      VoIPAppz::Commands::Console.command_guidance(%w(status))
        .should eq("unknown command `status` — run `help` to see available commands")
    {% else %}
      VoIPAppz::Commands::Console.command_guidance(%w(status)).should be_nil
    {% end %}
  end

  it "exposes the NATS client and ONLY the client — va-node is the executor" do
    top.should contain "nats"
    nested[["nats"]].should contain "request"
    # No `listen`: the CLI must never execute commands received over the bus.
    # The executor is va-crystal's KamailioExecutor (kamailio.command.sync).
    nested[["nats"]].should_not contain "listen"
  end

  it "keeps every SQLite-backed group under egress" do
    egress = nested[["sbc", "egress"]]
    sqlite_groups.each { |g| egress.should contain g }
  end

  it "keeps every SQLite-backed group AWAY from the ingress" do
    {% if flag?(:node_runtime) %}
      nested.has_key?(["sbc", "ingress"]).should be_false
    {% else %}
      ingress = nested[["sbc", "ingress"]]
      sqlite_groups.each { |g| ingress.should_not contain g }
    {% end %}
  end

  it "puts plane-wide HEP under trace, not under a box" do
    {% if flag?(:node_runtime) %}
      top.should_not contain "trace"
      nested.has_key?(["trace"]).should be_false
    {% else %}
      top.should_not contain "hep"
      nested[["trace"]].should contain "hep"
      nested[["sbc", "ingress"]].should_not contain "hep"
    {% end %}
    nested[["sbc", "egress"]].should_not contain "hep"
  end
end
