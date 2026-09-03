require "./spec_helper"
require "../src/helpers/node_install"

# The remote install is a shell script assembled from three untrusted-ish
# pieces — the answers, the installer body, and the wrapper — and it is
# executed by `sh -s` on someone else's machine. Everything here is about the
# seams between those pieces, because that is where it can silently break:
# a heredoc marker that is not at column 0 ends nothing, and the far side then
# reads the rest of the script as data.
describe VoIPAppz::NodeInstall do
  describe ".remote_script" do
    answers = "VA_API_URL=https://cloud.example.com\nVA_NATS_URL=nats://host:4222\n"

    it "puts every heredoc marker at the start of a line" do
      script = VoIPAppz::NodeInstall.remote_script(answers, {:url, "https://example.com/install.sh"})

      # Crystal's <<- strips indentation by the CLOSING delimiter, and the
      # pieces are INTERPOLATED — so an indented marker is a real possibility
      # and would not be visible by reading the source.
      script.lines.select(&.includes?("VAEOF")).each do |line|
        line.should eq(line.lstrip)
      end
    end

    it "removes the answer file whatever the installer exits with" do
      script = VoIPAppz::NodeInstall.remote_script(answers, {:url, "https://example.com/install.sh"})
      script.should contain("rm -f .env")
      # The installer's code is preserved, not the rm's — a failed install that
      # reports success is the one outcome worse than a failed install.
      script.should contain("exit $rc")
    end

    it "fetches when given a url" do
      script = VoIPAppz::NodeInstall.remote_script(answers, {:url, "https://example.com/install.sh"})
      script.should contain("curl -fsSL 'https://example.com/install.sh'")
      script.should_not contain("VAINSTALLER_EOF")
    end

    it "carries a local installer over the channel instead of fetching it" do
      path = File.tempname("installer", ".sh")
      File.write(path, "#!/bin/sh\necho installing\n")
      begin
        script = VoIPAppz::NodeInstall.remote_script(answers, {:path, path})
        # The point of --installer: the target never reaches for the network,
        # and never sees a URL it might resolve differently than we did.
        script.should_not contain("curl")
        script.should contain("echo installing")
        script.lines.select(&.includes?("VAINSTALLER_EOF")).each do |line|
          line.should eq(line.lstrip)
        end
      ensure
        File.delete?(path)
      end
    end

    # An installer containing the delimiter would end the heredoc early and
    # feed the remainder to the shell as commands. Refuse rather than generate
    # a script whose meaning depends on the file's contents.
    it "refuses an installer that contains the delimiter" do
      path = File.tempname("installer", ".sh")
      File.write(path, "#!/bin/sh\nVAINSTALLER_EOF\necho pwned\n")
      begin
        expect_raises(VoIPAppz::NodeInstall::Failed, /delimiter/) do
          VoIPAppz::NodeInstall.remote_script(answers, {:path, path})
        end
      ensure
        File.delete?(path)
      end
    end
  end

  describe ".installer?" do
    # `File.exists?` said yes to /dev/null, and an empty installer runs, exits
    # 0 and installs nothing — a deploy that reports success against a host
    # with no node on it.
    it "rejects a non-regular file" do
      VoIPAppz::NodeInstall.installer?("/dev/null").should be_false
    end

    it "rejects an empty file" do
      path = File.tempname("empty", ".sh")
      File.write(path, "")
      begin
        VoIPAppz::NodeInstall.installer?(path).should be_false
      ensure
        File.delete?(path)
      end
    end

    it "accepts a real script" do
      path = File.tempname("real", ".sh")
      File.write(path, "#!/bin/sh\nexit 0\n")
      begin
        VoIPAppz::NodeInstall.installer?(path).should be_true
      ensure
        File.delete?(path)
      end
    end
  end

  # install.sh takes flags of its own (`--no-register`, `--no-start`). The two
  # ways of launching it need DIFFERENT syntax for the same flag, and getting
  # the curl form wrong does not fail loudly: `curl … | sh --no-register` makes
  # sh treat it as the script's name, so the installer simply never starts and
  # the node is missing rather than misconfigured.
  describe ".command" do
    it "appends flags to a local installer" do
      VoIPAppz::NodeInstall.command({:path, "/opt/installer/install.sh"}, ["--no-register"])
        .should eq("sh '/opt/installer/install.sh' --no-register")
    end

    it "uses `sh -s --` when the installer is piped from curl" do
      VoIPAppz::NodeInstall.command({:url, "https://example.com/install.sh"}, ["--no-register"])
        .should eq("curl -fsSL 'https://example.com/install.sh' | sh -s -- --no-register")
    end

    it "adds no `-s --` when there is nothing to pass" do
      VoIPAppz::NodeInstall.command({:url, "https://example.com/install.sh"}, [] of String)
        .should eq("curl -fsSL 'https://example.com/install.sh' | sh")
    end
  end

  describe ".remote_script with flags" do
    answers = "VA_API_URL=https://cloud.example.com\n"

    it "passes them to an embedded installer" do
      path = File.tempname("installer", ".sh")
      File.write(path, "#!/bin/sh\necho hi\n")
      begin
        script = VoIPAppz::NodeInstall.remote_script(answers, {:path, path}, ["--no-register"])
        script.should contain("sh install.sh --no-register; rc=$?")
      ensure
        File.delete?(path)
      end
    end

    it "passes them to a fetched installer" do
      script = VoIPAppz::NodeInstall.remote_script(answers, {:url, "https://example.com/i.sh"}, ["--no-register"])
      script.should contain("| sh -s -- --no-register; rc=$?")
    end
  end

  describe ".answer_file" do
    it "carries the registry credential the installer would otherwise ask for" do
      ENV["VA_REGISTRY_USER"] = "ci"
      ENV["VA_REGISTRY_TOKEN"] = "tok"
      begin
        text = VoIPAppz::NodeInstall.answer_file({"VA_API_URL" => "https://cloud.example.com"})
        text.should contain("VA_REGISTRY_USER='ci'")
        text.should contain("VA_REGISTRY_TOKEN='tok'")
      ensure
        ENV.delete("VA_REGISTRY_USER")
        ENV.delete("VA_REGISTRY_TOKEN")
      end
    end
  end

  describe ".loopback?" do
    it "catches a mothership a remote node could never reach" do
      VoIPAppz::NodeInstall.loopback?({"VA_API_URL" => "http://127.0.0.1:5000"}).should be_true
      VoIPAppz::NodeInstall.loopback?({"VA_API_URL" => "http://localhost:5000"}).should be_true
      VoIPAppz::NodeInstall.loopback?({"VA_API_URL" => "https://cloud.example.com"}).should be_false
    end
  end
end
