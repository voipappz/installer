require "./spec_helper"
require "../src/helpers/app_deploy"

# The customer app (voipappz/app) deploys with Kamal, and its per-host
# destination files are hand-tuned — each one encodes a production incident in
# a comment. These specs pin the generator against the REAL hand-written
# config/deploy.pbx20.yml so a regression shows up here rather than as a failed
# deploy against a live PBX.
describe VoIPAppz::AppDeploy do
  # Mirrors the real pbx20 destination: an unprivileged deploy user on a node
  # whose Kong already owns 80/443.
  kong_dest = VoIPAppz::DeployDestination.from_yaml(<<-YAML)
    host: pbx20.itd-pbx.com
    user: itdroot
    ssh_port: 22
    key: "~/.ssh/kamal_deploy"
    YAML

  describe ".env_file_path" do
    it "uses a system path for root" do
      VoIPAppz::AppDeploy.env_file_path("root").should eq "/etc/voipappz/secrets.env"
    end

    # An unprivileged deploy user cannot write /etc without sudo, so their home
    # is the only place they can place the env-file. This is what the real
    # pbx20 and mtn destinations do.
    it "uses the deploy user's home for a non-root user" do
      VoIPAppz::AppDeploy.env_file_path("itdroot").should eq "/home/itdroot/voipappz-app.env"
    end
  end

  describe ".mothership_url" do
    it "is empty when no domain is configured — nothing to bake in" do
      VoIPAppz::AppDeploy.mothership_url(nil).should eq ""
    end

    it "ignores the placeholder domain a fresh va.yaml ships with" do
      config = VoIPAppz::DeployConfig.new
      config.organization.domain = "voipappz.local"
      VoIPAppz::AppDeploy.mothership_url(config).should eq ""
    end

    it "prefixes a bare domain with https" do
      config = VoIPAppz::DeployConfig.new
      config.organization.domain = "tenant.example.com"
      VoIPAppz::AppDeploy.mothership_url(config).should eq "https://tenant.example.com"
    end

    it "leaves an explicit scheme alone" do
      config = VoIPAppz::DeployConfig.new
      config.organization.domain = "http://tenant.internal"
      VoIPAppz::AppDeploy.mothership_url(config).should eq "http://tenant.internal"
    end
  end

  describe ".destination_yaml on a Kong host" do
    # Every field asserted here appears in the hand-written
    # ~/voipappz/app/config/deploy.pbx20.yml. If one drifts, the generated file
    # stops matching what is known to work in production.
    it "disables kamal-proxy so it cannot contend with Kong for 80/443" do
      yaml = VoIPAppz::AppDeploy.destination_yaml(kong_dest)
      yaml.should contain "proxy: false"
    end

    it "publishes on loopback only — the node's proxy fronts it" do
      yaml = VoIPAppz::AppDeploy.destination_yaml(kong_dest)
      yaml.should contain %(- "127.0.0.1:8888:3000")
    end

    it "carries the host and ssh identity" do
      yaml = VoIPAppz::AppDeploy.destination_yaml(kong_dest)
      yaml.should contain "- pbx20.itd-pbx.com"
      yaml.should contain "user: itdroot"
      yaml.should contain "port: 22"
      yaml.should contain %(- "~/.ssh/kamal_deploy")
    end

    it "points at the deploy user's env-file" do
      yaml = VoIPAppz::AppDeploy.destination_yaml(kong_dest)
      yaml.should contain "env-file: /home/itdroot/voipappz-app.env"
    end

    # A `proxy:` block alongside `proxy: false` would be contradictory, and
    # Kamal would still try to run kamal-proxy.
    it "emits no proxy block at all" do
      yaml = VoIPAppz::AppDeploy.destination_yaml(kong_dest)
      yaml.should_not contain "app_port:"
      yaml.should_not contain "healthcheck:"
    end

    it "bakes VITE_MOTHERSHIP_URL only when one is known" do
      VoIPAppz::AppDeploy.destination_yaml(kong_dest).should_not contain "VITE_MOTHERSHIP_URL"
      with_url = VoIPAppz::AppDeploy.destination_yaml(kong_dest, mothership: "https://t.example")
      with_url.should contain "VITE_MOTHERSHIP_URL: https://t.example"
      with_url.should contain "arch: amd64"
    end
  end

  describe ".destination_yaml on a bare host" do
    it "lets kamal-proxy front the app and health-check it" do
      yaml = VoIPAppz::AppDeploy.destination_yaml(kong_dest, kong: false)
      yaml.should contain "app_port: 3000"
      yaml.should contain "path: /health"
      yaml.should_not contain "proxy: false"
      # No fixed host port to collide on, so nothing is published.
      yaml.should_not contain "publish:"
    end
  end

  describe ".stop_first?" do
    # Kamal boots the new container before removing the old one. On a FIXED
    # host port the second bind fails with
    #   "Bind for 0.0.0.0:8888 failed: port is already allocated (exit 125)".
    it "stops the old container first only when publishing a fixed port" do
      VoIPAppz::AppDeploy.stop_first?(true).should be_true
      VoIPAppz::AppDeploy.stop_first?(false).should be_false
    end
  end

  describe ".healthcheck_url" do
    # Kamal's post-deploy hook probes this from the machine running the deploy.
    # Behind Kong the app is on loopback, unreachable from here — every probe
    # returns 000 and fails an otherwise-successful deploy.
    it "is empty behind Kong so the post-deploy hook skips itself" do
      VoIPAppz::AppDeploy.healthcheck_url(true, "tenant.example.com").should eq ""
    end

    it "is the public URL on a bare host" do
      VoIPAppz::AppDeploy.healthcheck_url(false, "tenant.example.com").should eq "https://tenant.example.com"
    end

    it "is empty when there is no domain to probe" do
      VoIPAppz::AppDeploy.healthcheck_url(false, "").should eq ""
    end
  end
end
