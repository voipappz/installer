require "./spec_helper"
require "../src/helpers/freeswitch"

describe VoIPAppz::FreeSwitch do
  it "builds an authenticated local ESL command" do
    args = VoIPAppz::FreeSwitch.cli_args("secret", ["-x", "status"], "18021")
    args.should eq([
      "fs_cli", "-H", "127.0.0.1", "-P", "18021", "-p", "secret",
      "-x", "status",
    ])
  end

  it "builds an authenticated interactive ESL command" do
    VoIPAppz::FreeSwitch.cli_args("secret", port: "8021").should eq([
      "fs_cli", "-H", "127.0.0.1", "-P", "8021", "-p", "secret",
    ])
  end
end
