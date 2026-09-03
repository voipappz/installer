require "admiral"
require "../helpers/docker"
require "../helpers/colors"
require "../helpers/services"

module VoIPAppz::Commands
  class Restart < Admiral::Command
    define_help description: "Restart services"

    define_argument service : String,
      description: "Specific service to restart (omit to restart all)"

    define_flag emergency : Bool,
      description: "Emergency restart (kill then start)",
      default: false,
      short: e
    define_flag profile : String,
      description: "Profile to restart: app or voip (default: app)",
      default: "app",
      short: p

    def run
      service = arguments.service

      if flags.emergency
        puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::BOLT} Emergency restart...")
        VoIPAppz::Docker.kill_all
        sleep 5.seconds
        VoIPAppz::Docker.compose_profiles!(["app", "voip"], ["up", "-d"])
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::ROCKET} Emergency restart completed")
      elsif service
        puts VoIPAppz::Colors.step(1, "Restarting #{VoIPAppz::Colors.cyan(service)}...")
        VoIPAppz::Docker.compose!(["restart", service])
        puts VoIPAppz::Colors.success("#{service} restarted")
      else
        unless ["app", "voip"].includes?(flags.profile)
          STDERR.puts VoIPAppz::Colors.error("Unknown profile: #{flags.profile}")
          STDERR.puts "  Valid profiles: app, voip"
          exit 1
        end
        profiles = VoIPAppz::Services.compose_profiles_for([flags.profile])
        puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ARROW} Restarting #{flags.profile} Services")
        VoIPAppz::Docker.compose_profiles!(profiles, ["down"])
        sleep 3.seconds
        VoIPAppz::Docker.compose_profiles!(profiles, ["up", "-d"])
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::ROCKET} #{flags.profile} services restarted")
      end
    end
  end
end
