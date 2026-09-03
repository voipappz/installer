require "admiral"
require "../helpers/docker"
require "../helpers/colors"
require "../helpers/freeswitch"

module VoIPAppz::Commands
  class Shell < Admiral::Command
    define_help description: "Open a shell in a service container"

    define_argument service : String,
      description: "Service name: db, kamailio, redis, freeswitch, cable, node"

    SHELL_COMMANDS = {
      "db"         => {container: "postgres", cmd: ["psql", "-U", "postgres", "-d", "freeswitch"]},
      "postgres"   => {container: "postgres", cmd: ["psql", "-U", "postgres", "-d", "freeswitch"]},
      "web"        => {container: "web", cmd: ["sh"]},
      "app"        => {container: "web", cmd: ["sh"]},
      "ingress"    => {container: "kamailio-ingress", cmd: ["kamctl"]},
      "egress"     => {container: "kamailio-egress", cmd: ["kamctl"]},
      "redis"      => {container: "redis", cmd: ["redis-cli"]},
      "freeswitch" => {container: "freeswitch", cmd: ["fs_cli"]},
      "cable"      => {container: "cable", cmd: ["sh"]},
      "node"       => {container: "node", cmd: ["sh"]},
    }

    def run
      service = arguments.service

      unless service
        puts VoIPAppz::Colors.bold("Available shells:")
        SHELL_COMMANDS.each do |name, config|
          puts "  #{VoIPAppz::Colors.cyan(name.ljust(12))} #{config[:cmd].join(" ")}"
        end
        return
      end

      config = SHELL_COMMANDS[service]?
      unless config
        STDERR.puts VoIPAppz::Colors.red("Unknown service: #{service}")
        STDERR.puts "Available: #{SHELL_COMMANDS.keys.join(", ")}"
        exit 1
      end

      puts VoIPAppz::Colors.bold("Opening #{service} shell...")
      container = VoIPAppz::Docker.resolve_container(config[:container])

      # Build the in-container command. fs_cli needs the ESL password passed
      # explicitly — without it, it falls back to the default `ClueCon` and
      # fails with "Error Connecting". The authoritative password is whatever
      # was substituted into the container's event_socket.conf.xml at boot, and
      # it ROTATES on FS recreate — so .env's VA_FREESWITCH_PASSWORD drifts out
      # of sync. Read the live value from the container first, fall back to .env.
      exec_cmd = config[:cmd].dup
      if service == "freeswitch"
        pw = VoIPAppz::FreeSwitch.esl_password(container)
        if pw.empty?
          STDERR.puts VoIPAppz::Colors.red("Cannot connect to FreeSWITCH: ESL password is unavailable.")
          exit 1
        end
        exec_cmd = VoIPAppz::FreeSwitch.cli_args(pw, exec_cmd[1..])
      end

      # Use docker exec (-it only when TTY available)
      docker_args = ["exec"]
      docker_args << "-it" if STDIN.tty?
      docker_args << container
      process = Process.new(
        "docker",
        docker_args + exec_cmd,
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      status = process.wait
      exit status.exit_code unless status.success?
    end

  end
end
