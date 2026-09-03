require "admiral"
require "../helpers/docker"
require "../helpers/colors"

module VoIPAppz::Commands
  class Logs < Admiral::Command
    define_help description: "Tail service logs"

    define_flag lines : Int32,
      description: "Number of lines to show",
      default: 100,
      short: n
    define_flag profile : String,
      description: "Show logs for profile: app, voip",
      short: p
    define_flag no_follow : Bool,
      description: "Don't follow log output",
      default: false

    define_argument service : String,
      description: "Service name to filter logs"

    PROFILE_SERVICES = {
      # Mirrors Services::ALL. The two kamailios are split by call direction:
      # the ingress forwarder is app-plane, the egress SBC is voip-plane.
      # minio is storage (started alongside app).
      "app"     => ["db", "redis", "nats", "minio", "kamailio-ingress", "web", "kong", "telegraf"],
      "voip"    => ["freeswitch", "node", "kamailio-egress"],
      "storage" => ["minio"],
    }

    def run
      service = arguments.service
      args = ["logs", "--tail", flags.lines.to_s]
      args << "-f" unless flags.no_follow

      if service
        args << service
        puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::BULLET} Tailing logs for #{VoIPAppz::Colors.cyan(service)}... (Ctrl+C to stop)")
      elsif flags.profile
        profile = flags.profile.not_nil!
        services = PROFILE_SERVICES[profile]?
        if services
          args += services
          puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::BULLET} Tailing logs for #{VoIPAppz::Colors.cyan(profile)} profile... (Ctrl+C to stop)")
        else
          STDERR.puts VoIPAppz::Colors.error("Unknown profile: #{profile}")
          STDERR.puts "  Valid profiles: app, voip"
          exit 1
        end
      else
        puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::BULLET} Tailing all logs... (Ctrl+C to stop)")
      end

      VoIPAppz::Docker.compose!(args)
    end
  end
end
