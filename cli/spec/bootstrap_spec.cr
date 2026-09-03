require "./spec_helper"
require "../src/helpers/bootstrap"

# Host provisioning mirrors `kamal server bootstrap`, implemented in Crystal.
describe VoIPAppz::Bootstrap do
  describe ".install_docker_cmd" do
    cmd = VoIPAppz::Bootstrap.install_docker_cmd

    it "uses the official get.docker.com convenience script (the Kamal way)" do
      cmd.should contain("https://get.docker.com")
      cmd.should_not contain("apt-get install") # not the old docker.io path
      cmd.should_not contain("docker.io")
    end

    it "is idempotent — skips when docker is already present" do
      cmd.should contain("which docker")
      cmd.should contain("||")
    end

    it "wraps the whole chain in bash -c so it runs under one sudo" do
      # ssh_run! sudo-prefixes only the first command in an A && B chain, so the
      # curl|sh install must live inside a single bash -c.
      cmd.should start_with("bash -c '")
      cmd.should contain("curl -fsSL")
      cmd.should contain("rm -f /tmp/get-docker.sh")
    end
  end

  describe ".enable_docker_cmd" do
    it "enables+starts docker on systemd, no-ops otherwise" do
      cmd = VoIPAppz::Bootstrap.enable_docker_cmd
      cmd.should contain("systemctl enable --now docker")
      cmd.should contain("command -v systemctl")
    end
  end

  describe ".add_user_to_docker_group_cmd" do
    it "adds the given user to the docker group" do
      VoIPAppz::Bootstrap.add_user_to_docker_group_cmd("ubuntu")
        .should eq("usermod -aG docker ubuntu")
    end
  end
end
