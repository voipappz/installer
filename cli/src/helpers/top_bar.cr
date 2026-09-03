module VoIPAppz::TopBar
  extend self

  WIDTH = 64

  def render(state : String, running : Int32, unhealthy : Int32) : String
    title = "+-- VOIPAPPZ -- SYSTEM #{state.upcase} -- #{running} up / #{unhealthy} unhealthy "
    top = title + "-" * {WIDTH - title.size - 1, 0}.max + "+"
    actions = "| [s] health  [c] containers  [l] logs  [h] help  [q] quit"
    middle = actions + " " * {WIDTH - actions.size - 1, 0}.max + "|"
    bottom = "+" + "-" * (WIDTH - 2) + "+"
    [top, middle, bottom].join('\n')
  end
end
