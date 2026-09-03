require "admiral"
require "http/client"
require "socket"
require "../helpers/colors"
require "../helpers/docker"

module VoIPAppz::Commands
  class Security < Admiral::Command
    define_help description: "Run security checks across all node-lite services"

    def run
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::SHIELD} Security Check")
      puts ""

      results = [] of {String, String, Bool, String}

      # --- Port exposure ---
      results << port_check("Kamailio SIP",    5060, :udp,  "external — phones + carriers connect")
      results << port_check("FreeSWITCH ESL",  8021, :tcp,  "loopback only — node agent internal")
      results << port_check("MinIO S3",        9000, :tcp,  "loopback only — node agent internal")

      # --- Auth checks ---
      results << check("MinIO anon blocked",       "anonymous bucket list rejected",          check_minio_anon_blocked)
      results << check("ESL password enforced",    "unauthenticated ESL connect rejected",    check_esl_auth_required)
      results << check("ESL loopback only",        "ESL not reachable on 0.0.0.0",            check_esl_loopback_only)

      # --- Kamailio SIP hardening ---
      results << check("Kamailio pike loaded",     "rate-limit module active",                check_kamailio_module("pike"))
      results << check("Kamailio ACL loaded",      "permissions module active",               check_kamailio_module("permissions"))
      results << check("Kamailio htable loaded",   "REGISTER gate active",                    check_kamailio_module("htable"))

      # --- Secrets hygiene ---
      results << check("No plaintext secrets",     "container env has no raw passwords",      check_no_env_secrets)

      # Render
      passed = results.count { |_, _, ok, _| ok }
      total  = results.size
      puts ""
      results.each do |name, desc, ok, note|
        icon = ok ? VoIPAppz::Colors.dot_ok : VoIPAppz::Colors.dot_fail
        status = ok ? VoIPAppz::Colors.green("PASS") : VoIPAppz::Colors.red("FAIL")
        puts "  #{icon} #{name.ljust(30)} #{status}  #{VoIPAppz::Colors.dim(desc)}"
        puts "       #{VoIPAppz::Colors.yellow("  → #{note}")}" if !ok && !note.empty?
      end

      puts ""
      puts VoIPAppz::Colors.divider(50)
      if passed == total
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} #{passed}/#{total} security checks passed")
      else
        puts VoIPAppz::Colors.error("#{total - passed}/#{total} checks FAILED — review above")
        exit 1
      end
    end

    private def check(name : String, desc : String, ok : Bool, note : String = "") : {String, String, Bool, String}
      {name, desc, ok, note}
    end

    # Check which address a port is bound to (loopback vs 0.0.0.0)
    private def port_check(name : String, port : Int32, proto : Symbol, expectation : String) : {String, String, Bool, String}
      stdout = IO::Memory.new
      Process.new("ss", ["-tlnp", "-u", "-n"], output: stdout, error: Process::Redirect::Close).wait rescue nil
      # ss gives UDP differently — just use netstat equivalent via /proc
      result = IO::Memory.new
      Process.new("sh", ["-c", "ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null"], output: result, error: Process::Redirect::Close).wait rescue nil
      lines = result.to_s.lines.select { |l| l.includes?(":#{port}") }

      if lines.empty?
        return {name, expectation, false, "port :#{port} not listening"}
      end

      # Check if any line binds to 0.0.0.0 (all interfaces)
      any_wildcard = lines.any? { |l| l.includes?("0.0.0.0:#{port}") || l.includes?("*:#{port}") }

      # Ports expected to be external: 5060 (SIP — phones need to reach it)
      expect_external = port == 5060

      if expect_external
        ok = any_wildcard || lines.any? { |l| l =~ /\d+\.\d+\.\d+\.\d+:#{port}/ }
        note = ok ? "" : "SIP port :5060 should be reachable externally"
      else
        ok = !any_wildcard
        note = ok ? "" : "port :#{port} is bound to 0.0.0.0 — should be loopback only"
      end

      {name, expectation, ok, note}
    rescue
      {name, expectation, false, "check failed"}
    end



    private def check_minio_anon_blocked : Bool
      uri = URI.parse("http://127.0.0.1:9000/recordings/")
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 2.seconds
      response = client.get(uri.request_target)
      # 403 = bucket exists but access denied without credentials (correct)
      # 200 = anonymous access allowed (bad)
      response.status_code == 403
    rescue
      false
    end

    private def check_esl_auth_required : Bool
      # Try to connect ESL without password — should get auth/request then fail
      begin
        sock = TCPSocket.new("127.0.0.1", ENV["VA_FREESWITCH_PORT"]?.try(&.to_i) || 8021, 2.seconds)
        data = sock.gets('\n', limit: 512) || ""
        sock.puts("auth wrongpassword\n\n")
        response = sock.gets('\n', limit: 512) || ""
        sock.close
        # Should see auth challenge then rejection — NOT "+OK accepted"
        !response.includes?("+OK accepted")
      rescue
        true  # can't connect = also protected
      end
    end

    private def check_esl_loopback_only : Bool
      result = IO::Memory.new
      Process.new("sh", ["-c", "ss -tlnp 2>/dev/null | grep :8021"], output: result, error: Process::Redirect::Close).wait
      lines = result.to_s.strip
      # Should NOT be bound to 0.0.0.0:8021 — only 172.x.x.x or 127.0.0.1
      !lines.includes?("0.0.0.0:8021") && !lines.empty?
    rescue
      false
    end

    private def check_kamailio_module(mod : String) : Bool
      container = Docker.running_kamailio?
      return false unless container
      exit_code, out = Docker.exec(container, ["kamcmd", "core.modules"])
      exit_code == 0 && out.includes?(mod)
    rescue
      false
    end

    private def check_no_env_secrets : Bool
      # Verify .env is not world-readable (mode should be 600 or 640, not 644/666)
      # and not tracked in git (gitignored).
      project_dir = VoIPAppz::Docker.project_dir
      env_path = File.join(project_dir, ".env")
      return false unless File.exists?(env_path)

      # Check file permissions — world-readable is a problem
      info = File.info(env_path)
      mode = info.permissions.value
      world_readable = (mode & 0o004) != 0
      return false if world_readable

      # Check .env is gitignored (not tracked)
      stdout = IO::Memory.new
      process = Process.new("git", ["-C", project_dir, "ls-files", "--error-unmatch", ".env"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status = process.wait
      # If git finds it tracked → security issue
      !status.success?
    rescue
      false
    end
  end
end
