require "./spec_helper"
require "file_utils"
require "../src/helpers/project"
require "../src/helpers/docker"

# WHY THIS EXISTS.
#
# Everything used to resolve against `Dir.current`: the compose file was the
# bare string "docker-compose.yaml", secrets/.env/config came from
# `Dir.current`, and the ingress dispatcher list was a relative path.
#
# That is true in a checkout and false on a node. `install.sh` puts the BINARY
# in /opt/cli/bin; `voipappz deploy` ships the PROJECT to /opt/va. Running
# `voipappz sbc ingress list` from where the binary lives reported the dispatcher
# file "missing" when it was present, and every compose command ran with chdir
# to a directory holding no docker-compose.yaml — so it did not error, it
# quietly acted on nothing.
#
# Not one test caught it, because every test ran from inside the project:
# test-ingress.sh cd's to its own repo root, CI runs in the checkout, and the
# specs run wherever crystal was invoked. They all encoded the assumption
# instead of challenging it. These specs challenge it.
describe VoIPAppz::Project do
  around_each do |example|
    saved_cwd = Dir.current
    saved_env = ENV["VA_PROJECT_DIR"]?
    ENV.delete("VA_PROJECT_DIR")
    VoIPAppz::Project.reset!
    begin
      example.run
    ensure
      Dir.cd(saved_cwd)
      saved_env ? (ENV["VA_PROJECT_DIR"] = saved_env) : ENV.delete("VA_PROJECT_DIR")
      VoIPAppz::Project.reset!
    end
  end

  it "finds the project from a subdirectory of it" do
    root = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
    begin
      File.write(File.join(root, "docker-compose.yaml"), "services: {}\n")
      deep = File.join(root, "a", "b")
      Dir.mkdir_p(deep)
      Dir.cd(deep)
      VoIPAppz::Project.reset!
      VoIPAppz::Project.root.should eq root
      VoIPAppz::Project.found?.should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end

  # WHERE A NODE'S PROJECT ACTUALLY IS.
  #
  # Two absolute locations are real: /opt/va, where `voipappz deploy` installs
  # a project, and /stack, where ci/Dockerfile.stack bakes one into the voip
  # image. /stack was missing from this list, so `docker exec <node> voipappz
  # status` — which lands in /usr/local/freeswitch, a directory with no compose
  # file in it or above it — resolved every project path against the cwd and
  # died on config/services.tsv.
  #
  # The ORDER is the assertion. A deployed project can be updated; a baked one
  # cannot, so on a host carrying both, /opt/va is the live one. Flipping these
  # two would make a node act on the image's frozen copy, which is the kind of
  # change that looks harmless in a diff.
  it "falls back to the deployed project before the image's baked one" do
    VoIPAppz::Project::FALLBACK_DIRS.should eq ["/opt/va", "/stack"]
  end

  # The exact shape of the node: cwd has no project, and the project is
  # somewhere else entirely.
  it "honours VA_PROJECT_DIR when the cwd is not the project" do
    root = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
    elsewhere = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
    begin
      File.write(File.join(root, "docker-compose.yaml"), "services: {}\n")
      Dir.cd(elsewhere)
      ENV["VA_PROJECT_DIR"] = root
      VoIPAppz::Project.reset!
      VoIPAppz::Project.root.should eq root
      VoIPAppz::Project.compose_file.should eq File.join(root, "docker-compose.yaml")
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(elsewhere)
    end
  end

  # Falling back to the cwd is correct — but the caller must be able to SAY the
  # project was not found, instead of reporting a present file as missing.
  it "reports not-found rather than pretending, when there is no project" do
    elsewhere = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
    begin
      Dir.cd(elsewhere)
      VoIPAppz::Project.reset!
      VoIPAppz::Project.found?.should be_false
    ensure
      FileUtils.rm_rf(elsewhere)
    end
  end

  it "builds absolute paths inside the project, never relative ones" do
    root = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
    begin
      File.write(File.join(root, "docker-compose.yaml"), "services: {}\n")
      ENV["VA_PROJECT_DIR"] = root
      VoIPAppz::Project.reset!
      p = VoIPAppz::Project.path("config", "kamailio", "ingress", "dispatcher.list")
      p.should start_with "/"
      p.should eq File.join(root, "config/kamailio/ingress/dispatcher.list")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

# A node deployed before the container rename (2026-08-03) runs ONE container
# called plainly `kamailio` — the full pre-split config, which is the SBC. The
# catalog only knew va-ingress/va-egress, so the CLI concluded no kamailio was
# running at all and every ingress/egress command refused on a healthy node.
describe "VoIPAppz::Docker legacy container" do
  it "treats a bare `kamailio` container as the EGRESS, not the ingress" do
    VoIPAppz::Docker.ingress?(VoIPAppz::Docker::LEGACY_KAMAILIO).should be_false
  end

  # Resolved from the catalog, never hardcoded — which is why renaming the
  # container to va-sbc (1f0f0e26) needed no change in docker.cr, only here.
  it "names the catalogued ingress container as the ingress" do
    VoIPAppz::Docker.ingress?("va-sbc").should be_true
  end
end
