require "json"
require "log"
require "mcp"

module VoIPAppz
  # What the stdio server reads off the wire, before mcp.cr sees it.
  #
  # mcp.cr maps each method to a request class whose `params` is not nilable,
  # so `{"method":"tools/list"}` — legal JSON-RPC, and how
  # `notifications/initialized` is always sent — raised in the parser. Give
  # every method-bearing message a `params` object.
  module McpWire
    def self.normalize(line : String) : String
      json = JSON.parse(line)
      hash = json.as_h?
      return line unless hash && hash.has_key?("method")
      return line unless hash["params"]?.nil? || hash["params"].raw.nil?
      hash["params"] = JSON::Any.new({} of String => JSON::Any)
      hash.to_json
    end
  end
end

# mcp.cr's ReadBuffer, as shipped (spider-gazelle/mcp.cr d6ca3e5, its latest):
#   • it looked for a newline anywhere in the buffer, consumed lines included,
#     so a request split across two reads was parsed half-read and lost;
#   • a line that failed to parse raised, and the transport took the raise as
#     "no more messages" — every request queued behind it waited for the next
#     read from stdin, which a client waiting on an answer never sends.
# Read only whole lines past the cursor, skip (and log) a bad one, and keep
# going.
module MCP::Shared
  class ReadBuffer
    def read_message : MCP::Protocol::JSONRPCMessage?
      loop do
        rest = @buffer.to_slice[@buffer.pos..]
        unless rest.index('\n'.ord.to_u8)
          @buffer.clear if rest.empty?
          return nil
        end
        line = @buffer.gets || return nil
        next if line.blank?
        begin
          return MCP::Protocol::JSONRPCMessage.from_json(VoIPAppz::McpWire.normalize(line))
        rescue ex
          ::Log.for("voipappz.mcp").warn { "dropped an MCP message that does not parse (#{ex.message}): #{line[0, 200]}" }
        end
      end
    end
  end
end
