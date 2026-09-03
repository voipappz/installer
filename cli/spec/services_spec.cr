require "./spec_helper"
require "../src/helpers/services"
require "../src/helpers/project"
require "file_utils"

# The catalog's agreement with docker-compose.yaml — which services exist and
# which profiles they are in — moved to scripts/check-services.sh, and the
# compose literal-string assertions to scripts/check-compose-contract.sh (both
# in `make test` and CI).
#
# They read this repo's compose file, and this source is moving to va-crystal
# where that file does not exist. See docs/next-cli-boundary.md, M1. The shell
# checks assert the same things and additionally run in the bare alpine CI
# container, which has no bash.
#
# What stays here is what belongs to the code: parsing the catalog, and the
# lookups every `docker exec` path depends on.
describe VoIPAppz::Services do
  # A MISSING CATALOG MUST READ AS A MISSING CATALOG.
  #
  # `.all` used to hand the path straight to File.read, so anywhere the stack
  # project is not — a va-crystal checkout, a `docker exec` into the node —
  # `voipappz status` printed "Unhandled exception ... File::NotFoundError"
  # over twenty-four `???` frames. The console banner shells out to `status`,
  # so opening the console printed that trace too.
  describe ".all without a catalog" do
    around_each do |example|
      saved = ENV["VA_PROJECT_DIR"]?
      ENV["VA_PROJECT_DIR"] = File.tempname.tap { |d| Dir.mkdir_p(d) }
      VoIPAppz::Project.reset!
      # BEFORE, not only after: another spec in this file has already called
      # `.all` and filled the memo, so without this the first example here sees
      # a populated catalog and nothing raises.
      VoIPAppz::Services.reset!
      begin
        example.run
      ensure
        FileUtils.rm_rf(ENV["VA_PROJECT_DIR"])
        saved ? (ENV["VA_PROJECT_DIR"] = saved) : ENV.delete("VA_PROJECT_DIR")
        VoIPAppz::Project.reset!
        VoIPAppz::Services.reset!
      end
    end

    it "reports it as a configuration problem, naming the path it looked at" do
      expected = VoIPAppz::Services.catalog_path
      ex = expect_raises(VoIPAppz::Services::CatalogMissing) { VoIPAppz::Services.all }
      ex.message.to_s.should contain(expected)
    end

    it "says what to do about it" do
      ex = expect_raises(VoIPAppz::Services::CatalogMissing) { VoIPAppz::Services.all }
      ex.message.to_s.should contain("VA_PROJECT_DIR")
    end

    it "lets a caller ask first instead of rescuing" do
      VoIPAppz::Services.available?.should be_false
    end
  end

  describe ".parse" do
    it "reads a catalog row into a Service" do
      svc = VoIPAppz::Services.parse("web\tva-app\tapp\tnet\t5000").first
      svc.name.should eq("web")
      svc.container.should eq("va-app")
      svc.profiles.should eq(["app"])
      svc.port.should eq(5000)
    end

    it "reads `-` as no published port rather than as port 0" do
      VoIPAppz::Services.parse("telegraf\tva-telegraf\tapp\tgear\t-").first.port.should be_nil
    end

    it "splits multiple profiles" do
      VoIPAppz::Services.parse("x\tva-x\tapp,voip\tbox\t-").first.profiles.should eq(["app", "voip"])
    end

    it "ignores comments and blank lines rather than inventing services" do
      VoIPAppz::Services.parse("# a comment\n\n").should be_empty
    end

    it "skips a short row instead of half-building a service" do
      VoIPAppz::Services.parse("web\tva-app\tapp\n").should be_empty
    end
  end

  describe "the shipped catalog" do
    it "carries the services a node cannot run without" do
      names = VoIPAppz::Services.all.map(&.name)
      names.should contain("kamailio-ingress")
      names.should contain("voip")
      # Absent until 2026-07-29, and `up` starts by name — so their absence
      # meant no syslog anywhere and no certificate, silently.
      names.should contain("telegraf")
      names.should contain("influxdb")
      names.should contain("acmesh")
    end

    it "maps role-named containers that do NOT track their service name" do
      VoIPAppz::Services.find?("web").not_nil!.container.should eq("va-app")
      VoIPAppz::Services.find?("kamailio-ingress").not_nil!.container.should eq("va-sbc")
      VoIPAppz::Services.find?("voip").not_nil!.container.should eq("va-voip")
    end

    it "finds a service by container name too — docker exec resolves both ways" do
      VoIPAppz::Services.find?("va-sbc").not_nil!.name.should eq("kamailio-ingress")
    end

    it "selects by profile" do
      VoIPAppz::Services.for_profile("voip").map(&.name).should eq(["voip"])
      VoIPAppz::Services.for_profile("app").map(&.name).should contain("kong")
      VoIPAppz::Services.for_profile("app").map(&.name).should_not contain("voip")
    end
  end
end
