require "./spec_helper"
require "../src/helpers/portal"
require "../src/helpers/kamal"

# A directory that looks like the portal: the server, and nothing else.
# config/deploy.yml and .kamal/ used to be markers too and would now reject the
# real thing; so would package.json, which the portal no longer has.
def with_portal(&)
  dir = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
  Dir.mkdir_p(File.join(dir, "connectix"))
  File.write(File.join(dir, "connectix", "mix.exs"), "# phoenix\n")
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end


# The portal is github.com/voipappz/app — its own repo, cloned beside this one.
# Its deploy policy is config/portal/ HERE. Every assertion below is about that
# boundary, because it is the one a rename can break silently across two repos.
describe VoIPAppz::Portal do
  describe ".portal?" do
    it "recognises a checkout by its SOURCE, not by deploy config" do
      with_portal do |dir|
        VoIPAppz::Portal.portal?(dir).should be_true
      end
    end

    # The regression this guards: config/deploy.yml and .kamal/ moved to
    # config/portal/ in the mothership repo on 2026-08-31. Requiring them here
    # made `voipappz portal` reject the real portal outright.
    it "does not require deploy config to live in the checkout" do
      with_portal do |dir|
        Dir.exists?(File.join(dir, ".kamal")).should be_false
        File.exists?(File.join(dir, "config", "deploy.yml")).should be_false
        VoIPAppz::Portal.portal?(dir).should be_true
      end
    end

    # connectix/mix.exs is the Phoenix portal, and it is the ONLY marker. The
    # pair before it — package.json + agents_demo/mix.exs — lost both halves at
    # once when the portal went pure BEAM: the React SPA was deleted and
    # agents_demo/ was renamed. `portal deploy` then refused before it started,
    # again telling you to re-clone the repo you were standing in.
    #
    # Dockerfile.production is deliberately NOT a marker — the customer-app
    # template ships one, and deploying a customer app to the portal's host is
    # the failure that reasoning prevents.
    it "rejects a project that only has a Dockerfile" do
      dir = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
      begin
        File.write(File.join(dir, "Dockerfile.production"), "FROM scratch\n")
        VoIPAppz::Portal.portal?(dir).should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    # The portal has no package.json and must never be identified by one: a
    # node project is exactly what this check has to tell the portal APART
    # from, now that the portal itself carries no node.
    it "rejects a node project" do
      dir = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
      begin
        File.write(File.join(dir, "package.json"), "{}\n")
        Dir.mkdir_p(File.join(dir, "node_modules"))
        VoIPAppz::Portal.portal?(dir).should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "recognises the portal with no package.json anywhere in it" do
      with_portal do |dir|
        File.exists?(File.join(dir, "package.json")).should be_false
        VoIPAppz::Portal.portal?(dir).should be_true
      end
    end
  end

  describe ".dir" do
    it "prefers an explicit path over the sibling" do
      with_portal do |dir|
        VoIPAppz::Portal.dir(dir).should eq dir
      end
    end

    it "explains where the portal is supposed to be when it is absent" do
      missing = File.join(File.tempname, "nope")
      ex = expect_raises(VoIPAppz::Portal::NotFound) { VoIPAppz::Portal.dir(missing) }
      ex.message.to_s.should contain "github.com/voipappz/app"
    end
  end

  describe ".conf_dir" do
    # ALWAYS this repo, never the checkout: the deploy policy is mothership's.
    it "resolves inside the project, not the portal checkout" do
      root = File.realpath(File.tempname.tap { |d| Dir.mkdir_p(d) })
      previous = ENV["VA_PROJECT_DIR"]?
      begin
        File.write(File.join(root, "docker-compose.yaml"), "services: {}\n")
        ENV["VA_PROJECT_DIR"] = root
        VoIPAppz::Project.reset!
        VoIPAppz::Portal.conf_dir.should eq File.join(root, "config", "portal")
      ensure
        # spec_helper sets this once with ||=; deleting it would strand every
        # spec that runs after this one.
        ENV["VA_PROJECT_DIR"] = previous if previous
        VoIPAppz::Project.reset!
        FileUtils.rm_rf(root)
      end
    end
  end

  describe ".secret_files" do
    # `kamal deploy -d <dest>` reads secrets-common and secrets.<dest> ONLY. A
    # precheck on .kamal/secrets passes and then the deploy dies inside the
    # container with "Secret 'KAMAL_REGISTRY_PASSWORD' not found".
    it "names what kamal actually reads for a destination" do
      files = VoIPAppz::Portal.secret_files("nimbus").map { |f| File.basename(f) }
      files.should eq ["secrets-common", "secrets.nimbus"]
      files.should_not contain "secrets"
    end

    it "falls back to plain secrets only for the default destination" do
      VoIPAppz::Portal.secret_files("").map { |f| File.basename(f) }.should eq ["secrets"]
    end
  end
end

describe VoIPAppz::Kamal do
  # The portal's source and its deploy policy are in two different repos, so
  # kamal is handed both: the checkout as the build context and git root, and
  # config/portal layered over it read-only.
  it "mounts the deploy config over the checkout" do
    cmd = VoIPAppz::Kamal.command("/src", ["deploy"], mount_root: "/src", conf_dir: "/ms/config/portal").join(" ")
    cmd.should contain "-v /src:/workdir"
    cmd.should contain "-v /ms/config/portal:/workdir/config:ro"
    cmd.should contain "-v /ms/config/portal/.kamal:/workdir/.kamal:ro"
  end

  it "leaves no trailing slash on the working directory" do
    cmd = VoIPAppz::Kamal.command("/src", ["deploy"], mount_root: "/src")
    cmd.should contain "/workdir"
    cmd.should_not contain "/workdir/"
  end

  it "mounts nothing extra when no deploy config is handed to it" do
    VoIPAppz::Kamal.command("/src", ["deploy"], mount_root: "/src").join(" ")
      .should_not contain ":/workdir/config"
  end
end
