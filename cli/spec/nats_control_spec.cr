require "./spec_helper"
require "../src/helpers/nats_control"

describe VoIPAppz::NatsControl do
  it "targets va-node's kamailio command subject" do
    VoIPAppz::NatsControl.subject("node-1").should eq("node:node-1:kamailio.command.sync")
  end

  it "builds a dispatcher.sync doorbell payload" do
    VoIPAppz::NatsControl.payload("dispatcher.sync").should eq(%({"action":"dispatcher.sync"}))
  end

  it "carries subscriber fields only when given" do
    body = VoIPAppz::NatsControl.payload("subscriber.add", "1001", "pbx.example.com", "s3cret")
    parsed = JSON.parse(body)
    parsed["action"].should eq("subscriber.add")
    parsed["username"].should eq("1001")
    parsed["domain"].should eq("pbx.example.com")
    parsed["password"].should eq("s3cret")
  end

  it "rejects arbitrary remote commands client-side" do
    expect_raises(Exception, /unsupported action/) do
      VoIPAppz::NatsControl.payload("shell")
    end
  end

  it "uses va.yaml values when docker exec has no inherited s6 environment" do
    saved_url = ENV["VA_NATS_URL"]?
    saved_nats_url = ENV["NATS_URL"]?
    saved_uuid = ENV["VA_NODE_UUID"]?
    saved_node_uuid = ENV["NODE_UUID"]?
    begin
      ENV["VA_NATS_URL"] = ""
      ENV["NATS_URL"] = ""
      ENV["VA_NODE_UUID"] = ""
      ENV["NODE_UUID"] = ""
      VoIPAppz::NatsControl.url("", "nats://broker:4222").should eq("nats://broker:4222")
      VoIPAppz::NatsControl.node_uuid("", "node-from-yaml").should eq("node-from-yaml")
    ensure
      saved_url ? (ENV["VA_NATS_URL"] = saved_url) : ENV.delete("VA_NATS_URL")
      saved_nats_url ? (ENV["NATS_URL"] = saved_nats_url) : ENV.delete("NATS_URL")
      saved_uuid ? (ENV["VA_NODE_UUID"] = saved_uuid) : ENV.delete("VA_NODE_UUID")
      saved_node_uuid ? (ENV["NODE_UUID"] = saved_node_uuid) : ENV.delete("NODE_UUID")
    end
  end
end
