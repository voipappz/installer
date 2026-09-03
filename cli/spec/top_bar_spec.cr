require "./spec_helper"
require "../src/helpers/top_bar"

describe VoIPAppz::TopBar do
  it "renders health and quick actions in a three-line ASCII bar" do
    bar = VoIPAppz::TopBar.render("running", 8, 0)
    bar.lines.size.should eq(3)
    bar.should contain("VOIPAPPZ -- SYSTEM RUNNING")
    bar.should contain("8 up / 0 unhealthy")
    bar.should contain("[s] health  [c] containers  [l] logs  [h] help  [q] quit")
    bar.lines.each { |line| line.size.should eq(VoIPAppz::TopBar::WIDTH) }
  end
end
