require "admiral"
require "./commands/*"

# Load .env from the current working directory so commands work without sudo -E
# or shell-sourcing. Existing process env wins (so explicit overrides still work).
{% begin %}
  env_path = File.join(Dir.current, ".env")
  if File.exists?(env_path) && File::Info.readable?(env_path)
    File.each_line(env_path) do |line|
      line = line.strip
      next if line.empty? || line.starts_with?('#')
      key, _, value = line.partition('=')
      key = key.strip
      next if key.empty? || ENV.has_key?(key)
      # Root mothership authorization is process-only. Do not make a value in
      # the auto-loaded .env silently persistent on a node box.
      next if key == "VA_API_AUTHORIZATION"
      value = value.strip
      if (value.starts_with?('"') && value.ends_with?('"')) ||
         (value.starts_with?('\'') && value.ends_with?('\''))
        value = value[1..-2]
      end
      ENV[key] = value
    end
  end
{% end %}

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
    {% unless flag?(:node_runtime) %}
      register_sub_command bootstrap, type: VoIPAppz::Commands::Bootstrap
      register_sub_command login, type: VoIPAppz::Commands::Login
      register_sub_command secrets, type: VoIPAppz::Commands::Secrets
      register_sub_command config, type: VoIPAppz::Commands::Config
    {% end %}

    # Day-to-day operations
    register_sub_command console, type: VoIPAppz::Commands::Console
    # These commands orchestrate the host's compose project. The CLI baked
    # into the node image has no docker client or compose project to drive, so
    # advertising them there turns a development command into a guaranteed
    # production failure. Normal builds retain the full development surface.
    {% unless flag?(:node_runtime) %}
      register_sub_command up, type: VoIPAppz::Commands::Up
      register_sub_command down, type: VoIPAppz::Commands::Down
      register_sub_command restart, type: VoIPAppz::Commands::Restart
      register_sub_command status, type: VoIPAppz::Commands::Status
      register_sub_command monitor, type: VoIPAppz::Commands::Monitor
      register_sub_command logs, type: VoIPAppz::Commands::Logs
      register_sub_command shell, type: VoIPAppz::Commands::Shell
    {% end %}
    {% if flag?(:node_runtime) %}
      # The in-container monitor: the same screen, fed by the node itself.
      register_sub_command monitor, type: VoIPAppz::Commands::NodeMonitor
    {% end %}
    register_sub_command health, type: VoIPAppz::Commands::Health
    register_sub_command switch, type: VoIPAppz::Commands::Switch
    register_sub_command nats, type: VoIPAppz::Commands::Nats

    # Testing & Deployment
    {% unless flag?(:node_runtime) %}
      register_sub_command syslog, type: VoIPAppz::Commands::Syslog
      register_sub_command checks, type: VoIPAppz::Commands::Checks
      register_sub_command test, type: VoIPAppz::Commands::Test
      register_sub_command app, type: VoIPAppz::Commands::App
      # the portal — voipappz/app, a sibling repo, host/docker commands throughout
      # (compose, npm-in-docker, kamal-in-docker), so it has no place in a node
      # build for the same reason `up` and `down` do not.
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
    {% end %}

    # SBC data plane. Ingress and egress stay explicit beneath one namespace,
    # so every operation names the Kamailio instance it targets.
    register_sub_command sbc, type: VoIPAppz::Commands::Sbc
    register_sub_command pbx, type: VoIPAppz::Commands::Pbx
    {% unless flag?(:node_runtime) %}
      register_sub_command trace, type: VoIPAppz::Commands::Trace
      register_sub_command security, type: VoIPAppz::Commands::Security
      # MCP is a host/development control plane. Its broad catalog deliberately
      # includes deployment commands that do not exist in the SIP image.
      register_sub_command mcp, type: VoIPAppz::Commands::Mcp
    {% end %}

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
