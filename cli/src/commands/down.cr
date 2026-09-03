require "admiral"
require "../helpers/docker"
require "../helpers/colors"

module VoIPAppz::Commands
  class Down < Admiral::Command
    define_help description: "Stop all services"

    define_flag emergency : Bool,
      description: "Emergency stop (kill all containers immediately)",
      default: false,
      short: e
    define_flag orphans : Bool,
      description: "Also remove orphan containers (no longer in compose)",
      default: false

    def run
      if flags.emergency
        puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::BOLT} EMERGENCY STOP \u2014 Killing all containers")
        VoIPAppz::Docker.kill_all
        puts VoIPAppz::Colors.success("All containers stopped")
      else
        puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ARROW} Stopping Services")
        args = ["down"]
        args << "--remove-orphans" if flags.orphans
        VoIPAppz::Docker.compose!(args)
        puts VoIPAppz::Colors.success("All services stopped")
      end
    end
  end
end
