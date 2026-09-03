require "admiral"
require "json"
require "../helpers/colors"
require "../helpers/table"

module VoIPAppz::Commands
  class Config < Admiral::Command
    define_help description: "Show configuration and endpoints"

    define_flag endpoints : Bool,
      description: "Show all service endpoints",
      default: false,
      short: e
    define_flag json : Bool,
      description: "Emit machine-readable JSON",
      default: false

    def run
      ENV["VOIPAPPZ_JSON"] = "1" if flags.json

      if flags.json
        emit_json
      elsif flags.endpoints
        show_endpoints
      else
        show_config
      end
    end

    # JSON shape: {"config": {<env keys>}, "endpoints": {<name>: <url>}}
    # Secret-bearing keys are masked (presence-only).
    private def emit_json
      env = load_env
      ip = env.fetch("VA_APP_INTERNAL_IP_ADDRESS", "127.0.0.1")
      secret_keys = %w[VA_POSTGRES_PASSWORD VA_FREESWITCH_PASSWORD VA_S3_KEY VA_S3_SECRET VA_INFLUX_TOKEN VA_SECRET_KEY_BASE]
      config = env.transform_values do |v|
        v
      end
      secret_keys.each { |k| config[k] = "<set>" if config.has_key?(k) && !config[k].empty? }

      endpoints = {
        "sip"        => "sip:#{ip}:5060",
        "websocket"  => "ws://#{ip}:4000/cable",
        "postgres"   => "#{ip}:5432",
        "redis"      => "#{ip}:6379",
        "minio"      => "http://#{ip}:9000",
        "kong_proxy" => "http://#{ip}:8000",
      }

      puts({"config" => config, "endpoints" => endpoints}.to_json)
    end

    private def show_config
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::GEAR} Configuration")
      puts ""

      env = load_env

      columns = [
        VoIPAppz::Table::Column.new("Setting", 28),
        VoIPAppz::Table::Column.new("Value", 40),
      ]

      rows = [
        ["Node UUID", env.fetch("VA_NODE_UUID", VoIPAppz::Colors.dim("not set"))],
        ["Hostname", env.fetch("VA_HOSTNAME", `hostname`.strip)],
        ["Environment", env.fetch("VA_ENVIRONMENT", "development")],
        ["Internal IP", VoIPAppz::Colors.cyan(env.fetch("VA_APP_INTERNAL_IP_ADDRESS", "127.0.0.1"))],
        ["External IP", VoIPAppz::Colors.cyan(env.fetch("VA_APP_EXTERNAL_IP_ADDRESS", "127.0.0.1"))],
        ["DB Address", VoIPAppz::Colors.cyan(env.fetch("VA_DB_ADDRESS", "127.0.0.1"))],
        ["Postgres User", env.fetch("VA_POSTGRES_USERNAME", "postgres")],
        ["FreeSWITCH Tag", env.fetch("VA_FREESWITCH_TAG", VoIPAppz::Colors.dim("not set"))],
        ["Crystal Tag", env.fetch("VA_CRYSTAL_TAG", VoIPAppz::Colors.dim("not set"))],
        ["S3 Endpoint", env.fetch("VA_S3_ENDPOINT", VoIPAppz::Colors.dim("not set"))],
        ["S3 Region", env.fetch("VA_S3_REGION", "us-east-1")],
        ["InfluxDB Host", VoIPAppz::Colors.cyan(env.fetch("VA_INFLUXDB_HOST", "influxdb"))],
        ["InfluxDB Port", env.fetch("VA_INFLUXDB_PORT", "8181")],
        ["Monitor Token", env.has_key?("VA_MONITOR_TOKEN") ? VoIPAppz::Colors.green("set") : VoIPAppz::Colors.dim("not set")],
      ]

      puts VoIPAppz::Table.render(columns, rows, title: "#{VoIPAppz::Colors::GEAR} Environment")
    end

    private def show_endpoints
      env = load_env
      ip = env.fetch("VA_APP_INTERNAL_IP_ADDRESS", "127.0.0.1")
      deploy_host = env.fetch("DEPLOY_HOST", "127.0.0.1")

      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::NET} Service Endpoints")
      puts ""

      columns = [
        VoIPAppz::Table::Column.new("Service", 20),
        VoIPAppz::Table::Column.new("Endpoint", 40),
      ]

      local_rows = [
        ["#{VoIPAppz::Colors::PHONE}  SIP Server", "sip:#{VoIPAppz::Colors.cyan(ip)}:5060"],
        ["#{VoIPAppz::Colors::BOLT}  WebSocket", "ws://#{VoIPAppz::Colors.cyan(ip)}:4000/cable"],
        ["#{VoIPAppz::Colors::DB}  PostgreSQL", "#{VoIPAppz::Colors.cyan(ip)}:5432"],
        ["#{VoIPAppz::Colors::DB}  Redis", "#{VoIPAppz::Colors.cyan(ip)}:6379"],
        ["#{VoIPAppz::Colors::LOCK}  SIP TLS", "#{VoIPAppz::Colors.cyan(ip)}:8443"],
        ["#{VoIPAppz::Colors::BOX}  Loki", "http://#{VoIPAppz::Colors.cyan(ip)}:3100"],
      ]

      puts VoIPAppz::Table.render(columns, local_rows, title: "#{VoIPAppz::Colors::NET} Local Endpoints")

      if deploy_host != "127.0.0.1"
        remote_rows = [
          ["#{VoIPAppz::Colors::PHONE}  SIP Server", "sip:#{VoIPAppz::Colors.cyan(deploy_host)}:5060"],
          ["#{VoIPAppz::Colors::BOLT}  WebSocket", "ws://#{VoIPAppz::Colors.cyan(deploy_host)}:4000/cable"],
          ["#{VoIPAppz::Colors::DB}  PostgreSQL", "#{VoIPAppz::Colors.cyan(deploy_host)}:5432"],
        ]
        puts VoIPAppz::Table.render(columns, remote_rows, title: "#{VoIPAppz::Colors::NET} Remote Endpoints (#{deploy_host})")
      end
    end

    private def load_env : Hash(String, String)
      env = {} of String => String
      project_dir = Path[__DIR__].parent.parent.parent.to_s
      env_path = File.join(project_dir, ".env")
      if File.exists?(env_path)
        File.each_line(env_path) do |line|
          line = line.strip
          next if line.empty? || line.starts_with?("#")
          if line.includes?("=")
            key, value = line.split("=", 2)
            env[key.strip] = value.strip
          end
        end
      end
      env
    end
  end
end
