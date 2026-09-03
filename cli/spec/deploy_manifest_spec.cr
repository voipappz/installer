require "./spec_helper"
require "../src/helpers/deploy_manifest"

# Regression guard for the pbx20 "empty-dir clobber" class of bug (2026-06-05):
# a docker-compose bind-mount whose source isn't present on the deploy target
# makes Docker create an empty dir and mount it OVER the image's baked config.
# Two flavors hit us: a relative config file missing from the deploy manifest
# (kamailio.lua), and absolute dev-tree mounts that don't exist on a target
# (FreeSWITCH /opt/src/...). These specs make both un-regressable.
describe VoIPAppz::DeployManifest do
  describe ".config_file_mounts" do
    it "extracts relative config-file bind-mount sources, stripping ./" do
      compose = <<-YAML
        services:
          kamailio:
            volumes:
              - ./kamailio.cfg:/etc/kamailio/kamailio.cfg
              - ./kamailio.lua:/etc/kamailio/kamailio.lua
              - ./data/kamailio:/var/lib/kamailio
              - /etc/localtime:/etc/localtime:ro
          node:
            volumes:
              - ./config/va.yaml:/tmp/node.yaml
              - node_data:/var/node
        YAML

      mounts = VoIPAppz::DeployManifest.config_file_mounts(compose)
      mounts.should contain("kamailio.cfg")
      mounts.should contain("kamailio.lua")
      mounts.should contain("config/va.yaml")
      # runtime data dir (no config extension), named volumes, and absolute
      # mounts are not config files to ship:
      mounts.should_not contain("data/kamailio")
      mounts.should_not contain("node_data")
    end

    it "de-duplicates repeated sources" do
      compose = "      - ./a.cfg:/x\n      - ./a.cfg:/y\n"
      VoIPAppz::DeployManifest.config_file_mounts(compose).should eq(["a.cfg"])
    end
  end

  describe ".missing_from_manifest" do
    it "flags a config-file mount that is absent from FILES" do
      compose = "      - ./brand-new.cfg:/etc/x\n"
      VoIPAppz::DeployManifest.missing_from_manifest(compose).should eq(["brand-new.cfg"])
    end

    it "returns empty when every config mount is in FILES" do
      compose = "      - ./config/kamailio/ingress/kamailio.cfg:/etc/kamailio/kamailio.cfg\n"
      VoIPAppz::DeployManifest.missing_from_manifest(compose).should be_empty
    end
  end

  describe ".dev_source_mounts" do
    it "flags absolute dev-tree mounts but allows OS-provided ones" do
      compose = <<-YAML
              - /etc/localtime:/etc/localtime:ro
              - /var/run/docker.sock:/var/run/docker.sock:ro
              - /opt/src/va-voipbox-freeswitch/conf/dialplan:/usr/local/freeswitch/conf/dialplan:ro
        YAML
      VoIPAppz::DeployManifest.dev_source_mounts(compose).should eq(
        ["/opt/src/va-voipbox-freeswitch/conf/dialplan"]
      )
    end
  end

  # The invariants against the REAL docker-compose.yaml moved to
  # scripts/check-deploy-manifest.sh (make test + CI).
  #
  # They read this repo's compose file, and this source is moving to va-crystal
  # where that file does not exist — a guard that cannot travel with the code it
  # guards has to stop being part of it. See docs/next-cli-boundary.md, M1. The
  # shell check asserts the same three things and additionally fires in the bare
  # alpine CI container, which has no bash.
  describe ".parse" do
    it "reads source, target and flags out of the manifest format" do
      text = <<-TSV
      # a comment
      docker-compose.yaml\t/opt/va/docker-compose.yaml
      .env\t/opt/va/.env\thost-generated

      kong.yaml\t/opt/va/config/kong/kong.yaml
      TSV
      parsed = VoIPAppz::DeployManifest.parse(text)
      parsed[:files]["docker-compose.yaml"].should eq("/opt/va/docker-compose.yaml")
      parsed[:files]["kong.yaml"].should eq("/opt/va/config/kong/kong.yaml")
      parsed[:files].size.should eq(3)
      parsed[:host_generated].should eq([".env"])
    end

    it "ignores comments and blank lines rather than shipping them" do
      VoIPAppz::DeployManifest.parse("# only a comment\n\n")[:files].should be_empty
    end

    it "skips a line with no target instead of shipping it nowhere" do
      VoIPAppz::DeployManifest.parse("orphan.yaml\n")[:files].should be_empty
    end
  end

  describe "the shipped manifest" do
    it "parses and carries the files a node cannot boot without" do
      files = VoIPAppz::DeployManifest.files
      files.has_key?("docker-compose.yaml").should be_true
      files.has_key?("config/kamailio/ingress/dispatcher.list").should be_true
      files["docker-compose.yaml"].should start_with("/opt/va")
    end

    it "marks the host-generated files, which never exist in a checkout" do
      VoIPAppz::DeployManifest.host_generated.should contain(".env")
      VoIPAppz::DeployManifest.host_generated.should contain("config/va.yaml")
    end
  end
end
