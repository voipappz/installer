require "admiral"
require "../helpers/colors"
require "../helpers/deploy_config"
require "../helpers/project"
require "../helpers/va_config"

module VoIPAppz::Commands
  # Print the node's local source-of-truth file exactly as it is stored.
  # This command is deliberately offline: only `voipappz sync` talks to the
  # mothership API.
  class Dump < Admiral::Command
    define_help description: "Print the current local config/va.yaml"

    def run
      path = ENV.fetch("VA_CONFIG_PATH", VoIPAppz::VaConfig.yaml_path(VoIPAppz::Project.root))
      unless File.exists?(path)
        STDERR.puts VoIPAppz::Colors.error("Missing #{path} — run `voipappz sync` first")
        exit 1
      end

      content = File.read(path)
      VoIPAppz::DeployConfig.from_yaml(content)
      print content
    rescue ex : YAML::ParseException
      STDERR.puts VoIPAppz::Colors.error("Invalid YAML in #{path}: #{ex.message}")
      exit 1
    end
  end
end
