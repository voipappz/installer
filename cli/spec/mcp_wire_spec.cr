require "./spec_helper"
require "../src/helpers/mcp_wire"

# The stdio server's read side. Each case is one a real client hit: nothing
# answered but `initialize`.
private def drain(buffer : MCP::Shared::ReadBuffer) : Array(MCP::Protocol::JSONRPCMessage)
  messages = [] of MCP::Protocol::JSONRPCMessage
  while message = buffer.read_message
    messages << message
  end
  messages
end

INITIALIZE = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"spec","version":"0"}}})
INITIALIZED = %({"jsonrpc":"2.0","method":"notifications/initialized"})
TOOLS_LIST = %({"jsonrpc":"2.0","id":2,"method":"tools/list"})

describe VoIPAppz::McpWire do
  it "gives a method without params an empty params object" do
    JSON.parse(VoIPAppz::McpWire.normalize(TOOLS_LIST))["params"].as_h.should be_empty
    JSON.parse(VoIPAppz::McpWire.normalize(%({"jsonrpc":"2.0","id":2,"method":"tools/list","params":null})))["params"].as_h.should be_empty
  end

  it "leaves params it was given, and responses, alone" do
    VoIPAppz::McpWire.normalize(INITIALIZE).should eq(INITIALIZE)
    response = %({"jsonrpc":"2.0","id":1,"result":{}})
    VoIPAppz::McpWire.normalize(response).should eq(response)
  end
end

describe MCP::Shared::ReadBuffer do
  it "reads every message of one chunk, params or not" do
    buffer = MCP::Shared::ReadBuffer.new
    buffer.append([INITIALIZE, INITIALIZED, TOOLS_LIST].join("\n") + "\n")
    messages = drain(buffer)
    messages.size.should eq(3)
    messages.last.should be_a(MCP::Protocol::ListToolsRequest)
  end

  it "keeps going past a line that does not parse" do
    buffer = MCP::Shared::ReadBuffer.new
    buffer.append("not json\n" + TOOLS_LIST + "\n")
    drain(buffer).map(&.class).should eq([MCP::Protocol::ListToolsRequest])
  end

  it "waits for the rest of a message split across reads" do
    buffer = MCP::Shared::ReadBuffer.new
    buffer.append(INITIALIZE + "\n" + TOOLS_LIST[0, 20])
    drain(buffer).size.should eq(1)
    buffer.append(TOOLS_LIST[20..] + "\n")
    drain(buffer).map(&.class).should eq([MCP::Protocol::ListToolsRequest])
  end
end
