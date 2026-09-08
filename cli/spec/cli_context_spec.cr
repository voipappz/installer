require "./spec_helper"
require "../src/helpers/cli_context"
require "../src/helpers/node_local"
require "file_utils"

# POINTING THE CLI AT ONE NODE OUT OF SEVERAL.
#
# A host carries a va.yaml per network — a `--network host` node and a bridge
# node with a pinned address — plus a .env per node beside it. `voipappz -f
# <va.yaml> --env-file <.env> <command>` is how a command says which pair it
# means, and these examples pin the two halves that can go quietly wrong: what
# is taken off ARGV (never a sub-command's own -f), and what the flags leave
# behind in the environment for every reader downstream.
describe VoIPAppz::CliContext do
  dir = ""
  yaml = ""
  env_file = ""

  around_each do |example|
    dir = File.tempname("va-context")
    Dir.mkdir_p(dir)
    yaml = File.join(dir, "va.bridge.yaml")
    env_file = File.join(dir, ".env.bridge")
    File.write(yaml, "nodes: []\n")
    File.write(env_file, "VA_VOIP_CONTAINER=va-voip-bridge\n")

    saved = {} of String => String?
    %w(VA_PATH VA_CONFIG_PATH VA_ENV_FILE INSTALL_DIR).each do |key|
      saved[key] = ENV[key]?
      ENV.delete(key)
    end
    begin
      example.run
    ensure
      FileUtils.rm_rf(dir)
      saved.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
      VoIPAppz::NodeLocal.reset!
    end
  end

  describe "what it takes off ARGV" do
    it "takes both flags before the sub-command and leaves the rest alone" do
      argv = ["-f", yaml, "--env-file", env_file, "sbc", "egress", "status"]
      VoIPAppz::CliContext.extract!(argv)
      argv.should eq(%w(sbc egress status))
    end

    it "takes the `--flag=value` spelling too" do
      argv = ["--file=#{yaml}", "--env-file=#{env_file}", "dump"]
      VoIPAppz::CliContext.extract!(argv)
      argv.should eq(%w(dump))
      ENV["VA_PATH"].should eq(yaml)
    end

    # `voipappz logs -f` is follow, and always was. The scan stops at the first
    # token that is not a global option, which is the sub-command.
    it "never touches a sub-command's own -f" do
      argv = ["logs", "-f", "voip"]
      VoIPAppz::CliContext.extract!(argv)
      argv.should eq(["logs", "-f", "voip"])
      ENV["VA_PATH"]?.should be_nil
    end

    it "leaves a bare invocation and --help alone" do
      argv = ["--help"]
      VoIPAppz::CliContext.extract!(argv)
      argv.should eq(["--help"])
    end
  end

  describe "what it leaves in the environment" do
    it "names the node document for every reader, absolute" do
      Dir.cd(dir) do
        VoIPAppz::CliContext.extract!(["-f", "va.bridge.yaml", "dump"])
      end
      ENV["VA_PATH"].should eq(yaml)
      # sbc and dump read VA_CONFIG_PATH first; an inherited one must not beat
      # the file just named on the command line.
      ENV["VA_CONFIG_PATH"].should eq(yaml)
    end

    it "makes the named pair the node NodeLocal resolves" do
      ENV["INSTALL_DIR"] = File.join(dir, "nowhere")
      VoIPAppz::CliContext.extract!(["-f", yaml, "--env-file", env_file, "health"])
      VoIPAppz::NodeLocal.reset!
      VoIPAppz::NodeLocal.yaml_path.should eq(yaml)
      VoIPAppz::NodeLocal.env_path.should eq(env_file)
      # A container name in that .env is how the second node's commands reach
      # the second node's container.
      VoIPAppz::NodeLocal.env["VA_VOIP_CONTAINER"].should eq("va-voip-bridge")
    end

    # `-f` says which document to read, not that a node was installed here.
    it "does not claim a node is installed on this host" do
      ENV["INSTALL_DIR"] = File.join(dir, "nowhere")
      VoIPAppz::CliContext.extract!(["-f", yaml, "health"])
      VoIPAppz::NodeLocal.installed?.should be_false
      VoIPAppz::NodeLocal.start_hint.should be_nil
    end
  end

  describe "what it refuses" do
    it "refuses a flag with no path" do
      expect_raises(VoIPAppz::CliContext::Error, /needs a path/) do
        VoIPAppz::CliContext.extract!(["-f"])
      end
      expect_raises(VoIPAppz::CliContext::Error, /needs a path/) do
        VoIPAppz::CliContext.extract!(["--env-file=", "dump"])
      end
    end

    # A node is one document; there is no second half of a va.yaml to overlay.
    it "refuses two different node documents" do
      expect_raises(VoIPAppz::CliContext::Error, /one node document at a time/) do
        VoIPAppz::CliContext.extract!(["-f", yaml, "-f", File.join(dir, "other.yaml"), "dump"])
      end
    end

    it "accepts the same file named twice" do
      argv = ["-f", yaml, "-f", yaml, "dump"]
      VoIPAppz::CliContext.extract!(argv)
      argv.should eq(%w(dump))
    end

    # `setup` is told to CREATE a node document, so the file may be absent —
    # its directory may not be, because a typo there writes one file and reads
    # another.
    it "allows a va.yaml that does not exist yet, but not in a missing directory" do
      fresh = File.join(dir, "va.new.yaml")
      VoIPAppz::CliContext.extract!(["-f", fresh, "setup"])
      ENV["VA_PATH"].should eq(fresh)

      expect_raises(VoIPAppz::CliContext::Error, /no directory/) do
        VoIPAppz::CliContext.extract!(["-f", File.join(dir, "typo", "va.yaml"), "setup"])
      end
    end

    # Nothing in the CLI writes a node's .env — install.sh and `make setup` do
    # — so a missing one loads no keys and every command that needed a secret
    # from it fails further down naming something else.
    it "refuses an env file that is not there" do
      expect_raises(VoIPAppz::CliContext::Error, /--env-file names this node's .env/) do
        VoIPAppz::CliContext.extract!(["--env-file", File.join(dir, "absent"), "health"])
      end
    end
  end
end
