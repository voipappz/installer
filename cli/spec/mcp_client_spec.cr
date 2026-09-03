require "./spec_helper"
require "http/server"
require "../src/helpers/mcp_client"

# The CLI as an MCP CLIENT. Two things are worth pinning and neither needs a
# real server: where a named server resolves to, and what happens when one
# answers something other than a result.
private def with_server(handler : HTTP::Server::Context -> Nil, &)
  server = HTTP::Server.new { |ctx| handler.call(ctx) }
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield VoIPAppz::McpClient::Server.new("stub", "http://127.0.0.1:#{address.port}/mcp", nil)
  ensure
    server.close
  end
end

describe VoIPAppz::McpClient do
  describe ".resolve" do
    it "knows the API's path, which is the whole reason names exist" do
      # /mcp, /api/mcp and /v1/mcp all answer 404 on voipappz-api. Typing the
      # path from memory is how you conclude the API has no MCP at all; the
      # route is /tasks/mcp.
      VoIPAppz::McpClient.resolve("api").url.should end_with("/tasks/mcp")
    end

    it "honours VA_API_PORT" do
      ENV["VA_API_PORT"] = "15000"
      begin
        VoIPAppz::McpClient.resolve("api").url.should eq("http://127.0.0.1:15000/tasks/mcp")
      ensure
        ENV.delete("VA_API_PORT")
      end
    end

    it "takes a URL as itself" do
      server = VoIPAppz::McpClient.resolve("https://example.com/mcp")
      server.url.should eq("https://example.com/mcp")
    end

    it "refuses a bare word that is not a known server" do
      # Not "assume it is a host": a typo would then become a connection
      # attempt to something invented, and the error would name a URL the
      # operator never typed.
      expect_raises(VoIPAppz::McpClient::Error, /unknown server/) do
        VoIPAppz::McpClient.resolve("portl")
      end
    end
  end

  describe ".call" do
    it "raises on a JSON-RPC error object instead of returning it as a result" do
      # The transport succeeded — HTTP 200 — and the request still failed. A
      # client that reads `result` without checking `error` reports success
      # here and prints nothing.
      handler = ->(ctx : HTTP::Server::Context) do
        ctx.response.print %({"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"Unknown resource"}})
        nil
      end
      with_server(handler) do |server|
        expect_raises(VoIPAppz::McpClient::Error, /-32002.*Unknown resource/) do
          VoIPAppz::McpClient.call(server, "resources/read", {uri: "voipappz://nope"})
        end
      end
    end

    it "names the URL it tried when the server answers a bad status" do
      # A 404 here is nearly always the wrong PATH rather than a missing
      # server, so the message has to carry the URL or it sends people to
      # check whether anything is running.
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.status_code = 404; nil }
      with_server(handler) do |server|
        expect_raises(VoIPAppz::McpClient::Error, /\/mcp answered 404/) do
          VoIPAppz::McpClient.call(server, "initialize")
        end
      end
    end

    it "refuses a 200 that is not JSON" do
      # A proxy or a login page where the MCP server should be.
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.print "<html>hi</html>"; nil }
      with_server(handler) do |server|
        expect_raises(VoIPAppz::McpClient::Error, /not JSON/) do
          VoIPAppz::McpClient.call(server, "initialize")
        end
      end
    end

    it "reports a server that is not listening as unreachable, not as empty" do
      server = VoIPAppz::McpClient::Server.new("dead", "http://127.0.0.1:1/mcp", nil)
      expect_raises(VoIPAppz::McpClient::Error, /not answering/) do
        VoIPAppz::McpClient.call(server, "initialize")
      end
    end
  end

  describe "list helpers" do
    it "read an absent list as empty rather than raising" do
      # `tools/list` legitimately returns [] on voipappz-api — it offers
      # resources only — so an absent or empty list is an answer, not a fault.
      handler = ->(ctx : HTTP::Server::Context) do
        ctx.response.print %({"jsonrpc":"2.0","id":1,"result":{}})
        nil
      end
      with_server(handler) do |server|
        VoIPAppz::McpClient.tools(server).should be_empty
        VoIPAppz::McpClient.resources(server).should be_empty
      end
    end
  end
end
