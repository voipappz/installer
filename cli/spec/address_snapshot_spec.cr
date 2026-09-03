require "./spec_helper"
require "../src/helpers/address_snapshot"

private def snapshot_row(ip : String, mask : Int32 = 32, tag : String = "provider", grp : Int32 = 2, port : Int32 = 0)
  VoIPAppz::AddressSnapshot::Row.new(grp, ip, mask, port, tag)
end

describe VoIPAppz::AddressSnapshot do
  it "keeps an identical provider snapshot" do
    provider = snapshot_row("198.51.100.10", 32, "provider-1")
    plan = VoIPAppz::AddressSnapshot.plan([provider], [provider], 2)
    plan.keep.should eq([provider])
    plan.remove.should be_empty
    plan.add.should be_empty
  end

  it "removes stale provider rows when the desired YAML is empty" do
    plan = VoIPAppz::AddressSnapshot.plan(
      [snapshot_row("198.51.100.10"), snapshot_row("198.51.100.11")],
      [] of VoIPAppz::AddressSnapshot::Row, 2)
    plan.remove.should eq([{grp: 2, ip: "198.51.100.10"}, {grp: 2, ip: "198.51.100.11"}])
    plan.add.should be_empty
  end

  it "recreates a provider whose mask or tag changed" do
    old = snapshot_row("198.51.100.0", 24, "old-provider")
    updated = snapshot_row("198.51.100.0", 23, "new-provider")
    plan = VoIPAppz::AddressSnapshot.plan([old], [updated], 2)
    plan.remove.should eq([{grp: 2, ip: "198.51.100.0"}])
    plan.add.should eq([updated])
  end

  it "does not touch address groups not owned by provider YAML" do
    plan = VoIPAppz::AddressSnapshot.plan(
      [snapshot_row("10.0.0.1", grp: 1)], [] of VoIPAppz::AddressSnapshot::Row, 2)
    plan.remove.should be_empty
  end

  it "rejects two providers that claim the same source IP differently" do
    expect_raises(ArgumentError, /multiple provider definitions/) do
      VoIPAppz::AddressSnapshot.plan([] of VoIPAppz::AddressSnapshot::Row,
        [snapshot_row("198.51.100.10", tag: "provider-1"), snapshot_row("198.51.100.10", tag: "provider-2")], 2)
    end
  end
end
