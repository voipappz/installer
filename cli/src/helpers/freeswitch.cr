require "./docker"

module VoIPAppz::FreeSwitch
  extend self

  CONFIG_PATH = "/usr/local/freeswitch/conf/autoload_configs/event_socket.conf.xml"

  # Build an explicit ESL connection. fs_cli's implicit defaults are unsafe for
  # this stack: the password is generated for each deployment and is never the
  # upstream ClueCon default.
  def cli_args(password : String, extra : Array(String) = [] of String,
               port : String = ENV["VA_FREESWITCH_PORT"]? || "8021") : Array(String)
    ["fs_cli", "-H", "127.0.0.1", "-P", port, "-p", password] + extra
  end

  # The rendered event_socket config is authoritative. Reading it also handles
  # nodes whose .env predates the running FreeSWITCH container. Fall back to the
  # host environment for older images that keep the config elsewhere.
  def esl_password(container : String) : String
    if VoIPAppz::Docker.local_exec?
      if File.exists?(CONFIG_PATH)
        if match = File.read(CONFIG_PATH).match(/name="password"\s+value="([^"]+)"/)
          password = match[1]
          return password unless password.empty?
        end
      end
      return ENV["VA_FREESWITCH_PASSWORD"]? || ""
    end

    output = IO::Memory.new
    status = Process.run("docker", [
      "exec", container, "sh", "-lc",
      %q{grep -oP 'name="password" value="\K[^"]+' /usr/local/freeswitch/conf/autoload_configs/event_socket.conf.xml | head -1},
    ], output: output, error: Process::Redirect::Close)
    password = status.success? ? output.to_s.strip : ""
    password.empty? ? (ENV["VA_FREESWITCH_PASSWORD"]? || "") : password
  rescue
    ENV["VA_FREESWITCH_PASSWORD"]? || ""
  end
end
