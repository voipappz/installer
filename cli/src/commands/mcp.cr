require "admiral"
require "log"
require "mcp"
require "../helpers/mcp_client"
require "../helpers/colors"

module VoIPAppz
  # MCP (Model Context Protocol) server exposing the voipappz CLI to MCP clients
  # (Claude Code, Cursor, any MCP client) over stdio. Tools shell back to THIS
  # binary, so the CLI stays the single source of truth — skills.md is the
  # command catalog, and the exit code is the contract.
  @[MCP::MCPServer(name: "voipappz", version: "0.1.0", tools: true, prompts: false, resources: false)]
  @[MCP::Transport(type: stdio)]
  class MCPServer
    include MCP::Annotator

    @[MCP::Tool(name: "voipappz_help",
      description: "Read-only discovery: show --help for a voipappz command. Pass the subcommand path (e.g. 'sbc egress address'); empty = top-level help. Start here to learn the command catalog.")]
    def voipappz_help(@[MCP::Param(description: "Subcommand path, space-separated, e.g. 'sbc egress dispatcher'. Empty for top-level.")] command : String) : String
      argv = command.strip.empty? ? [] of String : command.split
      MCPServer.run_cli(argv + ["--help"])
    end

    @[MCP::Tool(name: "voipappz_run",
      description: "Run a voipappz CLI command. Pass the full subcommand + flags as one string, e.g. 'status', 'health', 'sbc egress subscriber show', or 'sbc egress address add --grp 2 --ip 185.240.0.0/16 --tag carrier'. Returns exit code + stdout + stderr (exit 0 = success). SECURITY (server-enforced, default-deny): by default ONLY read-only commands run (status/health/config/env/logs/list, sbc ingress/egress list+status, sbc egress dispatcher status, sbc egress subscriber show, sbc egress trace status, trace hep status). Provisioning writes (sbc egress subscriber add/passwd, sbc egress address/dispatcher/domain add, sbc ingress/egress sync+reload) require VA_MCP_ALLOW_WRITE=1; everything else (lifecycle/deploy/clean/*remove*/secrets/shell) requires VA_MCP_UNRESTRICTED=1. Anything not permitted returns a 'refused:' message. NOTE: flag values containing spaces aren't supported here — use the CLI directly for those.")]
    def voipappz_run(@[MCP::Param(description: "voipappz subcommand and flags, e.g. 'sbc egress dispatcher status'")] command : String) : String
      MCPServer.run_cli(command.split)
    end

    # Tiered, default-deny guard — least privilege + prompt-injection protection.
    # The server does NOT trust the LLM:
    #   • default            → READ-only (observe, don't touch). Safe even for an
    #                          untrusted/autonomous agent.
    #   • VA_MCP_ALLOW_WRITE=1 → + safe provisioning (add subscriber/address/
    #                          dispatcher/domain, passwd, reload). OFF by default
    #                          because a rogue carrier ACL or subscriber is a real
    #                          toll-fraud risk — an operator opts in.
    #   • VA_MCP_UNRESTRICTED=1 → everything (lifecycle/deploy/clean/*remove*/
    #                          secrets/shell). Trusted, non-agent contexts only.
    READ = [
      ["status"], ["health"], ["config"], ["env"], ["logs"], ["syslog"], ["checks"], ["list"],
      ["sbc", "ingress", "list"], ["sbc", "ingress", "status"],
      ["sbc", "egress", "list"], ["sbc", "egress", "status"],
      ["sbc", "egress", "dispatcher", "status"],
      ["sbc", "egress", "subscriber", "show"],
      ["sbc", "egress", "trace", "status"], ["trace", "hep", "status"],
    ]
    WRITE = [
      ["sbc", "ingress", "reload"], ["sbc", "egress", "reload"],
      ["sbc", "ingress", "sync"], ["sbc", "egress", "sync"],
      ["sbc", "egress", "dispatcher", "add"],
      ["sbc", "egress", "address", "add"],
      ["sbc", "egress", "domain", "add"],
      ["sbc", "egress", "subscriber", "add"], ["sbc", "egress", "subscriber", "passwd"],
    ]

    def self.matches?(args : Array(String), set) : Bool
      set.any? { |prefix| args[0, prefix.size] == prefix }
    end

    def self.allowed?(args : Array(String)) : Bool
      return true if ENV["VA_MCP_UNRESTRICTED"]? == "1"
      return true if args.empty? || args.all?(&.starts_with?("-")) # bare / --help / --version
      return true if matches?(args, READ)
      return true if matches?(args, WRITE) && ENV["VA_MCP_ALLOW_WRITE"]? == "1"
      false
    end

    # Shell to THIS binary with the given argv (no shell → no shell injection).
    def self.run_cli(args : Array(String)) : String
      return "refused: 'mcp' cannot be invoked recursively" if args.first? == "mcp"
      unless allowed?(args)
        tier = matches?(args, WRITE) ? "a provisioning write — set VA_MCP_ALLOW_WRITE=1 to allow it" \
                                     : "destructive/sensitive — set VA_MCP_UNRESTRICTED=1 (trusted only)"
        return "refused: '#{args.join(" ")}' is not permitted via MCP (#{tier}). " \
               "Default is READ-ONLY: status, health, config, env, logs, syslog, checks, list, " \
               "sbc ingress/egress list+status, sbc egress dispatcher status, " \
               "sbc egress subscriber show, sbc egress trace status, trace hep status."
      end
      bin = Process.executable_path || "voipappz"
      outbuf = IO::Memory.new
      errbuf = IO::Memory.new
      status = Process.run(bin, args, output: outbuf, error: errbuf)
      String.build do |s|
        s << "exit=" << status.exit_code
        o = outbuf.to_s.strip
        e = errbuf.to_s.strip
        s << "\n" << o unless o.empty?
        s << "\n[stderr]\n" << e unless e.empty?
      end
    end
  end

  module Commands
    # The CLI binary IS the MCP server — STDIO ONLY, on purpose:
    #   • Local dev: Claude Code launches `voipappz mcp` via .mcp.json (on demand;
    #     the CLI does NOT run a server by default).
    #   • Remote site: run it over SSH (`ssh host … voipappz mcp`). The SSH key is
    #     the auth and there is NO network listener — a site is reachable ONLY via
    #     SSH. (No HTTP/0.0.0.0 transport: the shard's HTTP runner can't bind
    #     localhost-only, so we don't expose one.)
    class Mcp < Admiral::Command
      define_help description: "Run the MCP server over stdio so Claude/MCP clients can drive the CLI"

      # The CLI is also an MCP CLIENT now. The platform runs servers of its own
      # — voipappz-api at POST /tasks/mcp (resources: the live OpenAPI
      # contract, the Skill, the references), the portal's DuckDB tools at
      # POST :4001/mcp — and until this, the CLI could read none of them.
      #
      # Subcommands, not a separate top-level verb: `voipappz mcp` with no
      # arguments still starts the stdio server, which is what every .mcp.json
      # in the wild invokes. Breaking that to add a client would be a poor
      # trade.
      register_sub_command info, type: McpInfo
      register_sub_command resources, type: McpResources
      register_sub_command read, type: McpRead
      register_sub_command tools, type: McpTools

      def run
        # STDOUT is the JSON-RPC channel — keep it pure; logs → STDERR.
        ::Log.setup(:warn, ::Log::IOBackend.new(STDERR))
        STDERR.puts "voipappz mcp: stdio MCP server ready — connect an MCP client (e.g. Claude Code)"
        VoIPAppz::MCPServer.run
      end
    end

    # ---------------------------------------------------------------- client
    #
    # `--server` takes `api` (the default), `portal`, or a URL. The names are
    # not sugar: reaching the API from memory means guessing its path, and
    # /mcp, /api/mcp and /v1/mcp all answer 404 — the route is /tasks/mcp.

    # Admiral has no flag inheritance and a macro defined here is not in the
    # nested command classes' lookup path, so the flag is declared per verb.
    class McpInfo < Admiral::Command
      define_help description: "What an MCP server says it is, and what it offers"
      define_flag server : String,
        description: "api | portal | a URL (default: api)",
        default: "api",
        short: s

      def run
        server = VoIPAppz::McpClient.resolve!(flags.server)
        begin
          info = VoIPAppz::McpClient.handshake(server)
          si = info["serverInfo"]?
          puts VoIPAppz::Colors.bold("#{si.try(&.["name"]?.try(&.as_s?)) || server.name} #{si.try(&.["version"]?.try(&.as_s?))}")
          puts "  url:      #{server.url}"
          puts "  protocol: #{info["protocolVersion"]?.try(&.as_s?)}"
          caps = info["capabilities"]?.try(&.as_h?) || {} of String => JSON::Any
          puts "  offers:   #{caps.keys.empty? ? "(nothing declared)" : caps.keys.join(", ")}"
          # Counts, because "resources: {}" tells you a capability exists and
          # nothing about whether it is populated.
          puts "  tools:     #{VoIPAppz::McpClient.tools(server).size}"
          puts "  resources: #{VoIPAppz::McpClient.resources(server).size}"
        rescue ex : VoIPAppz::McpClient::Error
          STDERR.puts VoIPAppz::Colors.red(ex.message.to_s)
          exit 1
        end
      end
    end

    class McpResources < Admiral::Command
      define_help description: "List the resources an MCP server serves"
      define_flag server : String,
        description: "api | portal | a URL (default: api)",
        default: "api",
        short: s

      def run
        server = VoIPAppz::McpClient.resolve!(flags.server)
        begin
          list = VoIPAppz::McpClient.resources(server)
          if list.empty?
            puts VoIPAppz::Colors.dim("#{server.name} serves no resources")
            return
          end
          list.each do |r|
            puts VoIPAppz::Colors.bold(r["uri"]?.try(&.as_s?) || "?")
            if desc = r["description"]?.try(&.as_s?)
              puts "  #{desc}"
            end
            puts VoIPAppz::Colors.dim("  #{r["mimeType"]?.try(&.as_s?) || "-"}")
          end
        rescue ex : VoIPAppz::McpClient::Error
          STDERR.puts VoIPAppz::Colors.red(ex.message.to_s)
          exit 1
        end
      end
    end

    class McpRead < Admiral::Command
      define_help description: "Print one resource by uri"
      define_flag server : String,
        description: "api | portal | a URL (default: api)",
        default: "api",
        short: s
      define_argument uri : String, description: "Resource uri, e.g. voipappz://skill/SKILL.md", required: true

      def run
        server = VoIPAppz::McpClient.resolve!(flags.server)
        begin
          contents = VoIPAppz::McpClient.read(server, arguments.uri)
          if contents.empty?
            STDERR.puts VoIPAppz::Colors.yellow("#{arguments.uri} returned no contents")
            exit 1
          end
          # STDOUT stays the payload and nothing else, so this pipes.
          contents.each { |c| print(c["text"]?.try(&.as_s?) || c.to_json) }
        rescue ex : VoIPAppz::McpClient::Error
          STDERR.puts VoIPAppz::Colors.red(ex.message.to_s)
          exit 1
        end
      end
    end

    class McpTools < Admiral::Command
      define_help description: "List the tools an MCP server offers"
      define_flag server : String,
        description: "api | portal | a URL (default: api)",
        default: "api",
        short: s

      def run
        server = VoIPAppz::McpClient.resolve!(flags.server)
        begin
          list = VoIPAppz::McpClient.tools(server)
          if list.empty?
            # The API answers [] on purpose — a tool acts, acting needs a
            # scoped credential, and that endpoint is public. Say so, rather
            # than letting an empty list read as a fault.
            puts VoIPAppz::Colors.dim("#{server.name} offers no tools")
            return
          end
          list.each do |t|
            puts VoIPAppz::Colors.bold(t["name"]?.try(&.as_s?) || "?")
            if desc = t["description"]?.try(&.as_s?)
              puts "  #{desc.lines.first}"
            end
          end
        rescue ex : VoIPAppz::McpClient::Error
          STDERR.puts VoIPAppz::Colors.red(ex.message.to_s)
          exit 1
        end
      end
    end
  end
end
