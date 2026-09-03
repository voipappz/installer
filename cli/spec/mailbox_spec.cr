require "./spec_helper"
require "http/server"
require "../src/helpers/mailbox"

# `voipappz test mail` was scripts/check-auth-mail.sh, and tests/unit.sh tested
# it by putting a FAKE CURL on PATH — which worked only because the script's
# sole contact with the world was curl. A binary using HTTP::Client cannot be
# tested that way, so the seven scenarios that harness covered are re-made here
# against a real server on a real port. Same scenarios, and now they also
# exercise the HTTP client, the JSON parsing and the URL escaping, which the
# fake curl never touched.
#
# The verdict logic lives in the command; what is testable without a command
# object is the pair of questions everything else is built on — does the
# mailbox answer, and how many messages does it hold for this account.
private def with_mailbox(handler : HTTP::Server::Context -> Nil, &)
  server = HTTP::Server.new { |ctx| handler.call(ctx) }
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  # Give the fiber a turn to reach `listen` before anything connects.
  Fiber.yield
  begin
    ENV["MAILPIT_URL"] = "http://127.0.0.1:#{address.port}"
    ENV["API_URL"] = "http://127.0.0.1:#{address.port}"
    yield
  ensure
    ENV.delete("MAILPIT_URL")
    ENV.delete("API_URL")
    server.close
  end
end

describe VoIPAppz::Mailbox do
  it "reports a mailbox that does not answer, rather than an empty one" do
    # The distinction the whole check rests on: "no mail arrived" must never be
    # reachable when there was no mailbox to arrive in.
    with_mailbox(->(ctx : HTTP::Server::Context) { ctx.response.status_code = 404; nil }) do
      VoIPAppz::Mailbox.get("#{VoIPAppz::Mailbox.mail}/api/v1/info").should be_nil
      VoIPAppz::Mailbox.count("a@b.c").should eq(0)
    end
  end

  it "counts only the messages the mailbox reports for that account" do
    with_mailbox(->(ctx : HTTP::Server::Context) {
      ctx.response.print %({"messages_count":3,"messages":[{"ID":"x","Subject":"Your reset code"}]})
      nil
    }) do
      VoIPAppz::Mailbox.count("a@b.c").should eq(3)
      VoIPAppz::Mailbox.newest("a@b.c").try(&.["Subject"].as_s).should eq("Your reset code")
    end
  end

  it "narrows the search by subject, escaped" do
    # `to:a@b.c subject:"login code"` has a space, a quote and an @ in it. Sent
    # raw it is not a valid query string, and mailpit answers on the truncated
    # one — which counts EVERY message and turns a stale mailbox into a pass.
    seen = ""
    with_mailbox(->(ctx : HTTP::Server::Context) {
      seen = ctx.request.query_params["query"]? || ""
      ctx.response.print %({"messages_count":0,"messages":[]})
      nil
    }) do
      VoIPAppz::Mailbox.count("a@b.c", "login code")
    end
    seen.should eq(%(to:a@b.c subject:"login code"))
  end

  it "survives a body that is not JSON instead of raising" do
    # A proxy or a login page answering 200 where mailpit should be.
    with_mailbox(->(ctx : HTTP::Server::Context) { ctx.response.print "<html>nope</html>"; nil }) do
      VoIPAppz::Mailbox.count("a@b.c").should eq(0)
      VoIPAppz::Mailbox.newest("a@b.c").should be_nil
    end
  end

  it "posts the reset request form-encoded and returns the status" do
    body = ""
    with_mailbox(->(ctx : HTTP::Server::Context) {
      body = ctx.request.body.try(&.gets_to_end) || ""
      ctx.response.status_code = 503
      ctx.response.print "nope"
      nil
    }) do
      status, answer = VoIPAppz::Mailbox.post("/auth/forget_password", {"email" => "a@b.c"})
      # 503 is RETURNED, not raised: the command names the status in its own
      # error, which is how "an API error is named with its status" reads.
      status.should eq(503)
      answer.should eq("nope")
    end
    body.should eq("email=a%40b.c")
  end

  it "reports a refused connection as status 0 rather than crashing" do
    ENV["API_URL"] = "http://127.0.0.1:1"
    begin
      status, message = VoIPAppz::Mailbox.post("/auth/login", {"email" => "a@b.c"})
      status.should eq(0)
      message.should contain("did not answer")
    ensure
      ENV.delete("API_URL")
    end
  end

  it "resolves ports from the environment before .env" do
    ENV["VA_MAILPIT_PORT"] = "18025"
    begin
      VoIPAppz::Mailbox.mail.should eq("http://127.0.0.1:18025")
    ensure
      ENV.delete("VA_MAILPIT_PORT")
    end
  end
end
