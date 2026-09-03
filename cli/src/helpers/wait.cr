require "http/client"
require "./colors"
require "./docker"

module VoIPAppz::Wait
  def self.for_postgres(max_attempts : Int32 = 10, interval : Int32 = 5) : Bool
    container = VoIPAppz::Docker.resolve_container("postgres")
    puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::CLOCK} Waiting for PostgreSQL (#{container})...")
    max_attempts.times do |i|
      stdout = IO::Memory.new
      process = Process.new("docker", ["inspect", "--format", "{{.State.Health.Status}}", container],
        output: stdout, error: Process::Redirect::Close)
      process.wait
      health = stdout.to_s.strip
      if health == "healthy"
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::DB} PostgreSQL healthy")
        return true
      end
      # Also try direct pg_isready as backup
      exit_code, _ = VoIPAppz::Docker.exec(container, ["pg_isready", "-U", "postgres"])
      if exit_code == 0
        puts "  #{VoIPAppz::Colors::DB} PostgreSQL responding (docker health: #{health})"
      end
      puts "  #{VoIPAppz::Colors::CLOCK} Waiting for PostgreSQL... #{VoIPAppz::Colors.progress_bar(i + 1, max_attempts, 20)}"
      sleep interval.seconds
    end
    STDERR.puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::DB} PostgreSQL failed to become healthy")
    false
  end

  def self.for_redis(max_attempts : Int32 = 5, interval : Int32 = 3) : Bool
    container = VoIPAppz::Docker.resolve_container("redis")
    puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::CLOCK} Waiting for Redis (#{container})...")
    max_attempts.times do |i|
      # No auth: redis runs with `--protected-mode no` and no requirepass, and
      # there is no `redis_password` compose secret. The old probe cat'd a
      # nonexistent /run/secrets/redis_password and sent `AUTH ""`, which redis
      # rejects with "Client sent AUTH, but no password is set" — so this gate
      # ALWAYS failed and reported "Redis failed to become ready" on a healthy
      # redis. Keep this in step with the compose healthcheck (plain PING).
      exit_code, output = VoIPAppz::Docker.exec(container, ["redis-cli", "PING"])
      if exit_code == 0 && output.includes?("PONG")
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::BOX} Redis ready")
        return true
      end
      puts "  #{VoIPAppz::Colors::CLOCK} Waiting for Redis... #{VoIPAppz::Colors.progress_bar(i + 1, max_attempts, 20)}"
      sleep interval.seconds
    end
    STDERR.puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::BOX} Redis failed to become ready")
    false
  end

  # App-profile readiness gate = minio (recording sink). LavinMQ removed
  # 2026-07-10 (messaging moved to NATS); NATS has its own healthcheck + probe.
  def self.for_app_profile(ci : Bool = false) : Bool
    max = ci ? 20 : 10
    interval = ci ? 3 : 2
    for_minio(max, interval)
  end


  def self.for_minio(max_attempts : Int32 = 10, interval : Int32 = 2) : Bool
    puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::CLOCK} Waiting for MinIO (:9000)...")
    max_attempts.times do |i|
      begin
        client = HTTP::Client.new("127.0.0.1", 9000)
        client.connect_timeout = 2.seconds
        client.read_timeout = 2.seconds
        response = client.get("/minio/health/live")
        if response.status_code == 200
          puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::BOX} MinIO ready")
          return true
        end
      rescue
      end
      puts "  #{VoIPAppz::Colors::CLOCK} Waiting for MinIO... #{VoIPAppz::Colors.progress_bar(i + 1, max_attempts, 20)}"
      sleep interval.seconds
    end
    STDERR.puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::BOX} MinIO failed to become ready")
    false
  end

  def self.for_voip_profile(ci : Bool = false) : Bool
    max = ci ? 40 : 20
    interval = ci ? 5 : 5
    # License CLI wait disabled — license isn't relevant right now.
    # for_freeswitch(max, interval) && for_license_cli(max, interval)
    for_freeswitch(max, interval)
  end

  def self.for_freeswitch(max_attempts : Int32 = 20, interval : Int32 = 5) : Bool
    puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::CLOCK} Waiting for FreeSWITCH ESL (:8021)...")
    max_attempts.times do |i|
      begin
        container = VoIPAppz::Docker.resolve_container("freeswitch")
        pass = ENV["VA_FREESWITCH_PASSWORD"]? || "ClueCon"
        port = ENV["VA_FREESWITCH_PORT"]? || "8021"
        exit_code, output = VoIPAppz::Docker.exec(container, ["fs_cli", "-H", "127.0.0.1", "-P", port, "-p", pass, "-x", "status"])
        if exit_code == 0 && output.includes?("UP")
          puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::PHONE} FreeSWITCH ready")
          return true
        end
      rescue
      end
      puts "  #{VoIPAppz::Colors::CLOCK} Waiting for FreeSWITCH... #{VoIPAppz::Colors.progress_bar(i + 1, max_attempts, 20)}"
      sleep interval.seconds
    end
    STDERR.puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::PHONE} FreeSWITCH failed to become ready after #{max_attempts * interval}s")
    false
  end

  def self.for_license_cli(max_attempts : Int32 = 10, interval : Int32 = 3) : Bool
    puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::CLOCK} Waiting for License CLI in node container...")
    max_attempts.times do |i|
      begin
        container = VoIPAppz::Docker.resolve_container("node")
        exit_code, _ = VoIPAppz::Docker.exec(container, ["test", "-f", "/opt/license/license-cli"])
        if exit_code == 0
          puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::KEY} License CLI ready")
          return true
        end
      rescue
      end
      puts "  #{VoIPAppz::Colors::CLOCK} Waiting for License CLI... #{VoIPAppz::Colors.progress_bar(i + 1, max_attempts, 20)}"
      sleep interval.seconds
    end
    STDERR.puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::KEY} License CLI failed to become ready after #{max_attempts * interval}s")
    false
  end
end
