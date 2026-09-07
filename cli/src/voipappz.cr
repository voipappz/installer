require "admiral"
require "./commands/*"
require "./helpers/node_local"
require "./helpers/project"
require "./helpers/services"

# THE LOCAL ENVIRONMENT FILES, so commands work without `sudo -E` or shell
# sourcing. Existing process env always wins, so an explicit override still does.
#
# Two files, lowest precedence last:
#
#   ./.env                        the project or checkout you are standing in
#   <INSTALL_DIR>/.env            the node install.sh made on this host
#
# The second is what lets the kamailio and PBX commands work from a shell on a
# node box, where there is no checkout to stand in and the values they need
# (VA_FREESWITCH_PASSWORD, the service flags, the credentialed broker URL) live
# only in the installer's .env. It is read ONLY when this host has no compose
# project in reach: on a mothership box /opt/voipappz is that stack, not a node,
# and its .env must not be pulled in behind the operator's back. It is mode 0600
# owned by root, so without sudo this simply finds nothing and every command
# behaves as it did before.
def load_env_file(path : String) : Nil
  return unless File.exists?(path) && File::Info.readable?(path)
  File.each_line(path) do |line|
    line = line.strip
    next if line.empty? || line.starts_with?('#')
    key, _, value = line.partition('=')
    key = key.strip
    next if key.empty? || ENV.has_key?(key)
    # Root mothership authorization is process-only. Do not make a value in
    # an auto-loaded .env silently persistent on a node box.
    next if key == "VA_API_AUTHORIZATION"
    value = value.strip
    if (value.starts_with?('"') && value.ends_with?('"')) ||
       (value.starts_with?('\'') && value.ends_with?('\''))
      value = value[1..-2]
    end
    ENV[key] = value
  end
end

load_env_file(File.join(Dir.current, ".env"))
if !VoIPAppz::Project.found? && VoIPAppz::NodeLocal.installed?
  load_env_file(VoIPAppz::NodeLocal.env_path)
end

# Glue `--flag -<value>` → `--flag=-<value>` so negative-prefixed values
# (e.g. `--from -10m`) aren't misparsed as short-flag chains by Admiral.
i = 0
while i < ARGV.size - 1
  cur = ARGV[i]
  nxt = ARGV[i + 1]
  if cur.starts_with?("--") && !cur.includes?('=') &&
     nxt.size >= 2 && nxt[0] == '-' && nxt[1].ascii_number?
    ARGV[i] = "#{cur}=#{nxt}"
    ARGV.delete_at(i + 1)
  end
  i += 1
end

# `monitor` MEANS THE SCREEN THIS BOX CAN ACTUALLY DRAW.
#
# monitor.cr is a docker-plane TUI: every pane comes from `docker ps`,
# `docker logs` and `docker exec` across the compose services, and it needs
# config/services.tsv to know what those services are. node_monitor.cr is the
# same screen with every source swapped for the node's own answers — /health
# for the checks and counters, /capture for SIP — and no docker at all.
#
# Which one is right is a fact about the host, so it is decided here rather
# than by compiling two binaries. A catalog means a stack; no catalog means a
# node, or the inside of the image, where there is no docker socket by
# decision. Rewritten before Admiral parses, so each command still owns its own
# flags (--host on one, --capture on the other) instead of a merged set that
# half-works on both.
if ARGV.first? == "monitor" && !VoIPAppz::Services.available?
  ARGV[0] = "node-monitor"
end

module VoIPAppz
  class CLI < Admiral::Command
    define_version "0.1.0"
    define_help description: "VoIPAppz Infrastructure CLI"

    # Install & Setup
    register_sub_command setup, type: VoIPAppz::Commands::Setup
    register_sub_command node, type: VoIPAppz::Commands::Node
    register_sub_command sync, type: VoIPAppz::Commands::Sync
    register_sub_command dump, type: VoIPAppz::Commands::Dump
    register_sub_command env, type: VoIPAppz::Commands::Env
    register_sub_command bootstrap, type: VoIPAppz::Commands::Bootstrap
    register_sub_command login, type: VoIPAppz::Commands::Login
    register_sub_command secrets, type: VoIPAppz::Commands::Secrets
    register_sub_command config, type: VoIPAppz::Commands::Config

    # Day-to-day operations
    register_sub_command console, type: VoIPAppz::Commands::Console
    # These commands orchestrate a compose project. On a box that has no
    # catalog — a node, or inside the image, where there is no docker socket by
    # decision — they cannot work, and they say so: `Services.all` raises
    # CatalogMissing, which is the message an operator should get. They are
    # registered everywhere because there is ONE binary; what a command can do
    # is a fact about the host, decided when it runs, not when it is compiled.
    register_sub_command up, type: VoIPAppz::Commands::Up
    register_sub_command down, type: VoIPAppz::Commands::Down
    register_sub_command restart, type: VoIPAppz::Commands::Restart
    register_sub_command status, type: VoIPAppz::Commands::Status
    register_sub_command monitor, type: VoIPAppz::Commands::Monitor
    register_sub_command logs, type: VoIPAppz::Commands::Logs
    register_sub_command shell, type: VoIPAppz::Commands::Shell
    # The NODE monitor: the same screen, fed by the node's own /health and
    # /capture instead of docker. `monitor` on a host with no service catalog
    # is rewritten to this one before Admiral parses it (see below), so an
    # operator on a node box types `monitor` and gets the screen that works
    # there. It stays reachable under its own name for the other direction —
    # asking a node for its board from a host that does have a catalog.
    register_sub_command "node-monitor", type: VoIPAppz::Commands::NodeMonitor
    register_sub_command health, type: VoIPAppz::Commands::Health
    register_sub_command switch, type: VoIPAppz::Commands::Switch
    register_sub_command nats, type: VoIPAppz::Commands::Nats

    # Testing & Deployment
    register_sub_command syslog, type: VoIPAppz::Commands::Syslog
    register_sub_command checks, type: VoIPAppz::Commands::Checks
    register_sub_command test, type: VoIPAppz::Commands::Test
    register_sub_command app, type: VoIPAppz::Commands::App
    # the portal — voipappz/app, a sibling repo, host/docker commands throughout
    # (compose, npm-in-docker, kamal-in-docker), so it is a checkout's command
    # for the same reason `up` and `down` are.
    register_sub_command portal, type: VoIPAppz::Commands::Portal
    # TLS is this plane's business: acme.sh issues over DNS-01 into the certs
    # volume and Kong serves from it. va-crystal dropped this in 3d807ff
    # ("the voip plane terminates no TLS") — true of a node, and exactly
    # inverted here, where acmesh and Kong both run. `make cert` called it
    # throughout, and exited 2.
    register_sub_command cert, type: VoIPAppz::Commands::Cert
    register_sub_command deploy, type: VoIPAppz::Commands::Deploy
    register_sub_command backup, type: VoIPAppz::Commands::Backup
    register_sub_command db, type: VoIPAppz::Commands::Db
    register_sub_command clean, type: VoIPAppz::Commands::Clean

    # SBC data plane. Ingress and egress stay explicit beneath one namespace,
    # so every operation names the Kamailio instance it targets.
    register_sub_command sbc, type: VoIPAppz::Commands::Sbc
    register_sub_command pbx, type: VoIPAppz::Commands::Pbx
    register_sub_command trace, type: VoIPAppz::Commands::Trace
    register_sub_command security, type: VoIPAppz::Commands::Security
    # MCP is a host/development control plane. Its broad catalog deliberately
    # includes deployment commands that only a checkout can serve.
    register_sub_command mcp, type: VoIPAppz::Commands::Mcp

    def run
      # Claude-style: bare `voipappz` in a terminal opens the interactive
      # console; piped/scripted invocations keep printing help (safe for CI).
      if STDIN.tty? && STDOUT.tty?
        if bin = Process.executable_path
          Process.exec(bin, ["console"])
        end
      end
      puts help
    end
  end
end

# Friendly direct-shell UX. Admiral otherwise treats an unknown positional
# argument as a root argument, prints help, and exits 0 — dangerous in scripts
# because a typo looks successful. Keep validation tied to the console's
# command catalog so completion and direct invocation cannot drift.
if command = ARGV.first?
  case command
  when "help"
    ARGV.shift
    ARGV << "--help"
  when "version"
    ARGV[0] = "--version"
  else
    unless command.starts_with?("-") || VoIPAppz::Commands::Console::ROOT_COMMANDS.includes?(command)
      guidance = VoIPAppz::Commands::Console.command_guidance(ARGV) || "unknown command `#{command}`"
      STDERR.puts VoIPAppz::Colors.yellow(guidance)
      exit 2
    end
  end
end

VoIPAppz::CLI.run
