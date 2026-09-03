require "file_utils"
require "./spec_helper"
require "../src/helpers/docker"

# The CLI ships inside the voip image, so `docker exec va-voip voipappz …`
# works on a box with nothing installed and the CLI can never be a version
# behind the image it operates.
#
# Inside, kamctl / fs_cli / sqlite3 are processes in this container. Reaching
# them through the daemon instead was built and tried: it needs the socket
# mounted (root-equivalent on the host), a docker client in the image, and it
# failed on "container is not running" — a round trip to the host to start a
# process sitting next to the caller.
#
# So the same call dispatches two ways, decided by whether the tools are HERE.
# These specs drive that by putting a kamctl on PATH, because the alternative —
# trusting /.dockerenv — is true both inside the voip image and inside a CI job
# container that mounts the docker socket to drive the stack, which need
# opposite behaviour.
private def with_kamctl_on_path(present : Bool, &)
  original_path = ENV["PATH"]
  dir = File.tempname("kamctl-probe")
  Dir.mkdir_p(dir)

  if present
    fake = File.join(dir, "kamctl")
    File.write(fake, "#!/bin/sh\nexit 0\n")
    File.chmod(fake, 0o755)
    ENV["PATH"] = "#{dir}:#{original_path}"
  else
    # A PATH with nothing on it at all: no kamctl, and nothing else either.
    ENV["PATH"] = dir
  end

  VoIPAppz::Docker.reset_local_exec!
  begin
    yield
  ensure
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
    VoIPAppz::Docker.reset_local_exec!
  end
end

describe VoIPAppz::Docker do
  describe ".local_exec?" do
    it "is on when kamctl is on this box — that is what a node looks like" do
      with_kamctl_on_path(true) { VoIPAppz::Docker.local_exec?.should be_true }
    end

    it "is off when it is not — a workstation, or a CI runner driving docker" do
      with_kamctl_on_path(false) { VoIPAppz::Docker.local_exec?.should be_false }
    end
  end

  describe ".exec" do
    it "runs the command here, ignoring the container name" do
      with_kamctl_on_path(true) do
        # A container name that cannot exist: if this ever goes back through
        # `docker exec`, it fails rather than passing for the wrong reason.
        code, out = VoIPAppz::Docker.exec("no-such-container", ["/bin/echo", "from-the-node"])

        code.should eq 0
        out.should eq "from-the-node"
      end
    end

    it "reports a missing binary as 127 rather than raising" do
      with_kamctl_on_path(true) do
        code, _ = VoIPAppz::Docker.exec("ignored", ["definitely-not-installed-anywhere"])
        code.should eq 127
      end
    end

    it "carries the exit code through, so callers still branch on failure" do
      with_kamctl_on_path(true) do
        code, _ = VoIPAppz::Docker.exec("ignored", ["/bin/sh", "-c", "exit 3"])
        code.should eq 3
      end
    end

    it "captures and strips stdout, the same as the docker path" do
      with_kamctl_on_path(true) do
        _, out = VoIPAppz::Docker.exec("ignored", ["/bin/sh", "-c", "printf '  spaced  \\n'"])
        out.should eq "spaced"
      end
    end
  end

  # This is what lets every command work unchanged: resolution finds LOCAL
  # running, so nothing needs a special case for being inside a container.
  describe ".running_containers" do
    it "answers with this box when the tools are here" do
      with_kamctl_on_path(true) do
        VoIPAppz::Docker.running_containers.should eq [VoIPAppz::Docker::LOCAL]
      end
    end
  end
end

# `docker compose` HAS NO LOCAL EQUIVALENT, and local-exec mode used to imply
# one. The compose path asked `ensure_docker!`, which returns early for
# anything local — so inside the voip image, where local_exec? is true and no
# docker binary exists, `voipappz status` reached Process.new("docker", ...)
# and died with an unhandled File::NotFoundError over nineteen `???` frames.
#
# The two answers must be able to disagree: kamctl is here, the plane is not.
describe "compose in local-exec mode" do
  it "does not treat a local kamctl as a working compose" do
    with_kamctl_on_path(true) do
      VoIPAppz::Docker.reset_docker_check!
      VoIPAppz::Docker.local_exec?.should be_true
      VoIPAppz::Docker.compose_available?.should be_false
    end
  end

  it "sees compose when docker is genuinely on PATH" do
    VoIPAppz::Docker.reset_local_exec!
    VoIPAppz::Docker.reset_docker_check!
    # Only meaningful on a machine that has docker; the suite runs in one.
    if Process.find_executable("docker")
      VoIPAppz::Docker.compose_available?.should be_true
    end
  end
end
