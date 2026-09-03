require "./spec_helper"
require "../src/helpers/gatus"

# Gatus is the source of truth for whether a node is healthy, so the part that
# turns its JSON into a verdict is the part worth pinning. Everything here runs
# against a recorded body — no server, no ports, no waiting — which is the
# reason parse/failing are separate from fetch at all.
#
# The three shapes that decide a verdict, and all three have been got wrong
# before: a red probe in an UNGATED group (must not fail the node), a probe
# with NO RESULT YET (must not count as healthy), and the newest result being
# the one that counts (gatus returns a history, oldest first).
BODY = <<-JSON
[
  {"group": "app", "name": "postgres",
   "results": [{"success": false, "conditionResults": [{"condition": "[STATUS] == 200", "success": false}]},
               {"success": true,  "conditionResults": [{"condition": "[STATUS] == 200", "success": true}]}]},
  {"group": "app", "name": "kong",
   "results": [{"success": true, "conditionResults": [{"condition": "[STATUS] == 200", "success": true}]}]},
  {"group": "sip", "name": "ingress",
   "results": [{"success": false,
                "conditionResults": [{"condition": "[STATUS] == 200", "success": false},
                                     {"condition": "[RESPONSE_TIME] < 500", "success": true}]}]},
  {"group": "scratch", "name": "an ungated probe",
   "results": [{"success": false, "conditionResults": [{"condition": "[STATUS] == 200", "success": false}]}]},
  {"group": "metrics", "name": "never probed", "results": []}
]
JSON

describe VoIPAppz::Gatus do
  describe ".parse" do
    board = VoIPAppz::Gatus.parse(BODY)

    it "reads every endpoint" do
      board.size.should eq(5)
    end

    it "takes the NEWEST result, not the first" do
      # postgres failed and then recovered. Reading results[0] would report a
      # healthy node as down for as long as gatus keeps that history.
      board.find! { |e| e.name == "postgres" }.up.should be_true
    end

    it "names only the conditions that actually failed" do
      ingress = board.find! { |e| e.name == "ingress" }
      ingress.up.should be_false
      ingress.detail.should eq("[STATUS] == 200")
      ingress.detail.should_not contain("RESPONSE_TIME")
    end

    it "treats an endpoint with no result as NOT healthy" do
      # Never answered is a different thing from answered correctly. On a stack
      # that just came up this is the normal state for a few seconds, which is
      # what the wait exists for — but it is never a pass.
      never = board.find! { |e| e.name == "never probed" }
      never.up.should be_false
      never.detail.should eq("no result yet")
    end
  end

  describe ".failing" do
    board = VoIPAppz::Gatus.parse(BODY)

    it "ignores a red probe in an ungated group" do
      names = VoIPAppz::Gatus.failing(board).map(&.name)
      names.should contain("ingress")
      names.should contain("never probed")
      names.should_not contain("an ungated probe")
    end

    it "is empty when every gated group is green" do
      green = VoIPAppz::Gatus.parse(%([{"group":"app","name":"web","results":[{"success":true}]}]))
      VoIPAppz::Gatus.failing(green).should be_empty
    end

    it "honours an explicit gate list" do
      VoIPAppz::Gatus.failing(board, ["scratch"]).map(&.name).should eq(["an ungated probe"])
    end
  end

  describe ".gated_groups" do
    it "defaults to the four planes a node is judged on" do
      VoIPAppz::Gatus.gated_groups.should eq(%w(app sip voip metrics))
    end

    it "can be overridden, comma or space separated" do
      ENV["VA_GATUS_GATED_GROUPS"] = "app, sip"
      begin
        VoIPAppz::Gatus.gated_groups.should eq(["app", "sip"])
      ensure
        ENV.delete("VA_GATUS_GATED_GROUPS")
      end
    end
  end

  describe ".render" do
    it "stars the gated rows and names the failed condition" do
      out = VoIPAppz::Gatus.render(VoIPAppz::Gatus.parse(BODY))
      out.should contain("ingress")
      out.should contain("[STATUS] == 200")
      out.should contain("* = gated")
    end
  end

  describe ".parse on something that is not a board" do
    it "refuses HTML rather than reporting an empty, healthy node" do
      # A proxy or a login page answering 200 is the failure mode that would
      # otherwise parse to zero endpoints and zero failures — a green verdict
      # from a server that never spoke to gatus at all.
      expect_raises(VoIPAppz::Gatus::Unreachable) { VoIPAppz::Gatus.parse("<html>nope</html>") }
      expect_raises(VoIPAppz::Gatus::Unreachable) { VoIPAppz::Gatus.parse(%({"endpoints": []})) }
    end
  end
end
