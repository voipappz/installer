require "./spec_helper"
require "file_utils"
require "../src/helpers/runner"
require "../src/helpers/services"

# Deploying the app plane means running docker compose ON THE NODE — the CLI is
# already there and so is the repo. SSH is for the case that genuinely needs a
# network hop: shipping the `voip` profile to a separate switch box. Both are
# the same three operations, so the deploy steps and the verification are
# written once against Runner.
describe VoIPAppz::LocalRunner do
  it "reports the exit code and the output together" do
    runner = VoIPAppz::LocalRunner.new
    code, output = runner.run("echo hello")
    code.should eq 0
    output.strip.should eq "hello"
  end

  it "captures stderr too — a failure explains itself or it is useless" do
    code, output = VoIPAppz::LocalRunner.new.run("echo boom >&2; exit 3")
    code.should eq 3
    output.should contain "boom"
  end

  # bash is not guaranteed — alpine and other minimal images ship busybox sh
  # only, and hardcoding it turned a missing shell into "Error executing
  # process: 'bash'", which says nothing about the deploy.
  it "falls back to sh when bash is absent" do
    VoIPAppz::LocalRunner.shell.should eq(Process.find_executable("bash") ? "bash" : "sh")
  end

  it "runs commands inside the project directory" do
    dir = File.tempname
    Dir.mkdir_p(dir)
    begin
      _, output = VoIPAppz::LocalRunner.new(dir).in_project("pwd")
      File.realpath(output.strip).should eq File.realpath(dir)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # Local "upload" is a copy, and File.copy TRUNCATES its destination before
  # reading the source — so copying a file onto itself destroys it. Locally the
  # source and destination are routinely the same path, because the repo is
  # already where the deploy wants it.
  it "does not destroy a file by copying it onto itself" do
    dir = File.tempname
    Dir.mkdir_p(dir)
    path = File.join(dir, "keep.txt")
    begin
      File.write(path, "precious")
      VoIPAppz::LocalRunner.new(dir).upload(path, path).should be_true
      File.read(path).should eq "precious"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "knows it is local, so failure hints do not tell you to ssh into yourself" do
    VoIPAppz::LocalRunner.new.local?.should be_true
    VoIPAppz::SSHRunner.new("1.2.3.4", "root", nil, "~/.ssh/id_rsa", 22).local?.should be_false
  end
end

describe "VoIPAppz::Services.expected_for" do
  # A deploy must verify exactly what it started. Verifying `voip` on an
  # app-only node would fail a perfectly good deploy.
  it "expects only the profiles being deployed" do
    VoIPAppz::Services.expected_for(["voip"]).should_not contain "kong"
    VoIPAppz::Services.expected_for(["app"]).should contain "kong"
  end

  # The voip plane is ONE container now (the merged kamailio + FreeSWITCH +
  # node image), and the broker moved to the app plane with the rest of the
  # ancillary services. That is safe only because the node can reach a remote
  # broker: its NATS startup check is FATAL — startup_checks.cr exits 1 after
  # its retries, unlike the FreeSWITCH and InfluxDB probes — so a voip node
  # with no reachable broker crash-loops.
  #
  # What replaces the local broker is the `nats:$VA_NATS_HOST` extra_host on
  # the voip service, which is what makes VA_NATS_URL resolve to the app plane
  # (or a SaaS broker). Assert that, or nothing guards the invariant this test
  # used to hold: a voip deploy must still be able to find NATS.
  it "deploys the voip plane as a single service" do
    expected = VoIPAppz::Services.expected_for(["voip"])
    expected.should contain "voip"
    expected.should_not contain "nats"
    expected.should_not contain "acmesh"
  end

  # `up` adds both of these to the app plane, and they are not in the catalog:
  # web writes recordings to MinIO, and the init one-shots are not services.
  it "adds storage and the init one-shots to the app plane" do
    expected = VoIPAppz::Services.expected_for(["app"])
    expected.should contain "minio"
    expected.should contain "createbuckets"
    expected.should contain "db-init"
  end

  it "does not drag storage or init containers into a voip-only deploy" do
    expected = VoIPAppz::Services.expected_for(["voip"])
    expected.should_not contain "minio"
    expected.should_not contain "db-init"
  end

  it "deduplicates a combined deploy" do
    combined = VoIPAppz::Services.expected_for(["app", "voip"])
    combined.size.should eq combined.uniq.size
  end
end
