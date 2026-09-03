require "./spec_helper"
require "../src/helpers/docker"

# Guards the class of bug where an operator command aimed at a test stack lands
# on the live one. Role-based resolution assumes a service sits in the container
# named for its role on a deploy node (freeswitch -> va-voip), which is wrong
# for va-crystal's CI stack — kamailio, FreeSWITCH and the node share ONE
# s6-supervised container — and wrong for any host carrying a second stack
# beside production. Without the override, `voipappz pbx cli` pointed at a test
# environment silently attaches to the real PBX.
#
# Pure env parsing, so no docker required. `resolve_container` itself is not
# exercised here: it shells out to `docker ps`.
# Env is process-global, so each example restores what it found. Defined at
# file scope: Crystal cannot declare a def inside a describe block.
private def with_env(key : String, value : String?, &)
  previous = ENV[key]?
  value ? (ENV[key] = value) : ENV.delete(key)
  begin
    yield
  ensure
    previous ? (ENV[key] = previous) : ENV.delete(key)
  end
end

describe VoIPAppz::Docker do
  describe ".container_override" do
    it "is nil when unset, so role-based resolution still runs" do
      with_env("VA_FREESWITCH_CONTAINER", nil) do
        VoIPAppz::Docker.container_override("freeswitch").should be_nil
      end
    end

    it "returns the container named for the service" do
      with_env("VA_FREESWITCH_CONTAINER", "va-stack-ci") do
        VoIPAppz::Docker.container_override("freeswitch").should eq("va-stack-ci")
      end
    end

    # A dashed service name has to reach the same variable sbc.cr has always
    # honored, or the two disagree about where the egress lives.
    it "maps dashes in the service name to underscores" do
      with_env("VA_KAMAILIO_EGRESS_CONTAINER", "va-stack-ci") do
        VoIPAppz::Docker.container_override("kamailio-egress").should eq("va-stack-ci")
      end
    end

    # An exported-but-empty variable is what a shell leaves behind for an unset
    # value (VA_FREESWITCH_CONTAINER=""). Treating that as a container name
    # would resolve every command to "" and fail with an empty container name.
    it "treats an empty value as unset" do
      with_env("VA_FREESWITCH_CONTAINER", "   ") do
        VoIPAppz::Docker.container_override("freeswitch").should be_nil
      end
    end

    it "strips surrounding whitespace" do
      with_env("VA_NODE_CONTAINER", "  va-stack-ci\n") do
        VoIPAppz::Docker.container_override("node").should eq("va-stack-ci")
      end
    end
  end
end
