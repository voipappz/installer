require "admiral"
require "../helpers/docker"
require "../helpers/colors"
require "../helpers/table"
require "../helpers/sip"
require "../helpers/sipp/runner"
require "../helpers/sipp/builtin"
require "../helpers/project"
require "../helpers/mailbox"

module VoIPAppz::Commands
  class Test < Admiral::Command
    define_help description: "Run SIP and platform tests"

    # Everything above this line probes ONE call at a time. A scenario is the
    # other axis: media, DTMF and a sustained call rate, driven by SIPp.
    register_sub_command scenario, type: SippScenario
    # The APP's front door, not the SIP one: was scripts/check-auth-mail.sh and
    # scripts/check-login.sh.
    register_sub_command mail, type: AuthMail
    register_sub_command login, type: LoginFlow

    define_flag level : String,
      description: "Test level: ping, invite, call, register, quick, medium, heavy, full, platform",
      default: "quick",
      short: l
    define_flag stress : Bool,
      description: "Run stress test instead of load test",
      default: false
    define_flag calls : Int32,
      description: "Number of concurrent calls",
      default: 10,
      short: c
    define_flag duration : Int32,
      description: "Duration in seconds",
      default: 30,
      short: d
    define_flag target : String,
      description: "Target IP address (default: the SIP address from config/va.yaml)",
      default: "",
      short: t
    define_flag port : Int32,
      description: "Target SIP port",
      default: 5060
    define_flag user : String,
      description: "SIP user to call, and the auth username when --password is given",
      short: u,
      default: "100"
    define_flag password : String,
      description: "SIP password, for a proxy that challenges (401/407)",
      default: ""
    define_flag domain : String,
      description: "SIP domain",
      default: "test.voipappz.com"

    def run
      case flags.level
      when "quick"
        run_load(calls: 5, duration: 10)
      when "medium"
        run_load(calls: 25, duration: 30)
      when "heavy"
        run_load(calls: 100, duration: 60)
      when "full"
        run_full
      when "platform"
        run_platform
      when "ping"
        # Native SIP OPTIONS — no sipexer, so CI and health can rely on it.
        run_ping
      when "call"
        run_dialog
      when "invite"
        run_invite
      when "register"
        run_register
      else
        if flags.stress
          run_stress(calls: flags.calls, duration: flags.duration)
        else
          run_load(calls: flags.calls, duration: flags.duration)
        end
      end
    end

    private def run_full
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::STAR} Comprehensive Test Suite")
      puts ""
      run_ping
      run_register
      run_call(duration: 10)
      run_load(calls: flags.calls, duration: flags.duration)
      puts ""
      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::STAR} Comprehensive test suite completed")
    end

    private def container_running?(name : String) : Bool
      _, output = VoIPAppz::Docker.compose(["ps", "--status", "running", "--quiet", name], capture: true)
      !output.strip.empty?
    end

    private def run_platform
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ROCKET} Platform Tests")
      puts ""
      errors = [] of String
      step = 0

      # 1. Check containers
      step += 1
      puts VoIPAppz::Colors.step(step, "Checking containers...")
      exit_code, output = VoIPAppz::Docker.compose(["ps"], capture: true)
      if output.includes?("Up") || output.includes?("running")
        puts VoIPAppz::Colors.success("Containers running")
      else
        errors << "Containers not running"
        puts VoIPAppz::Colors.error("Containers not running")
      end

      # 2. Check PostgreSQL (app profile — skip if not deployed here)
      step += 1
      puts VoIPAppz::Colors.step(step, "Testing PostgreSQL... #{VoIPAppz::Colors::DB}")
      if container_running?("db")
        exit_code, _ = VoIPAppz::Docker.exec_t("db", ["pg_isready", "-U", "postgres"])
        if exit_code == 0
          puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::DB} PostgreSQL ready")
        else
          errors << "PostgreSQL not ready"
          puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::DB} PostgreSQL not ready")
        end
      else
        puts VoIPAppz::Colors.warning("#{VoIPAppz::Colors::DB} PostgreSQL not on this node — skipped")
      end

      # 3. Check Redis (app profile — skip if not deployed here)
      step += 1
      puts VoIPAppz::Colors.step(step, "Testing Redis... #{VoIPAppz::Colors::BOX}")
      if container_running?("redis")
        exit_code, output = VoIPAppz::Docker.exec("redis", ["redis-cli", "ping"])
        if exit_code == 0 && output.includes?("PONG")
          puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::BOX} Redis ready")
        else
          errors << "Redis not ready"
          puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::BOX} Redis not ready")
        end
      else
        puts VoIPAppz::Colors.warning("#{VoIPAppz::Colors::BOX} Redis not on this node — skipped")
      end

      # 4. Check API (app profile — skip if not deployed here)
      step += 1
      puts VoIPAppz::Colors.step(step, "Testing API health... #{VoIPAppz::Colors::NET}")
      if container_running?("api")
        begin
          client = HTTP::Client.new("127.0.0.1", 5000)
          client.connect_timeout = 3.seconds
          client.read_timeout = 3.seconds
          response = client.get("/health")
          if response.status_code == 200 || response.status_code == 503
            puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::NET} API responding (#{response.status_code})")
          else
            errors << "API returned #{response.status_code}"
            puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::NET} API returned #{response.status_code}")
          end
        rescue
          errors << "API not reachable"
          puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::NET} API not reachable")
        end
      else
        puts VoIPAppz::Colors.warning("#{VoIPAppz::Colors::NET} API not on this node — skipped")
      end

      # 5. SIP test
      step += 1
      puts VoIPAppz::Colors.step(step, "Testing SIP service... #{VoIPAppz::Colors::PHONE}")
      if sipexer_available?
        run_ping
      else
        puts VoIPAppz::Colors.warning("sipexer not found, skipping SIP test")
      end

      puts ""
      puts VoIPAppz::Colors.divider(50)
      if errors.empty?
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} Platform test completed \u2014 all checks passed!")
      else
        puts VoIPAppz::Colors.error("Platform test completed \u2014 #{errors.size} check(s) failed")
        errors.each { |e| puts VoIPAppz::Colors.error(e) }
        exit 1
      end
    end

    # OPTIONS/REGISTER are native (helpers/sip.cr) — no sipexer, so these can
    # never silently skip. INVITE/load/stress below still shell out to sipexer,
    # which does real work (dialogs, SDP, concurrency) worth not reimplementing.
    # kamailio binds the auto-detected NIC address
    # (VA_APP_INTERNAL_IP_ADDRESS), not loopback, so with no --target we probe
    # that or the check misses a healthy proxy.
    #
    # The flag defaults to EMPTY, not "127.0.0.1". It used to default to
    # loopback and then treat that exact value as "unset" — which made an
    # explicit `--target 127.0.0.1` indistinguishable from no flag at all, so it
    # was silently replaced by the config address. On a configured node you
    # could not probe loopback, and the CLI reported testing an address you had
    # not asked for.
    private def sip_target : String
      flags.target.empty? ? VoIPAppz::SIP.default_host : flags.target
    end

    private def sip_port : Int32
      # Same contract as sip_target above: an EXPLICIT --port always wins.
      # VA_TEST_SIP_PORT only fills in when the flag was left at its default —
      # otherwise the env silently redirected `--port 25060` probes at a test
      # fixture to the LIVE node's port, and the ingress suite asserted
      # against the wrong kamailio entirely.
      return flags.port if flags.port != 5060
      ENV["VA_TEST_SIP_PORT"]?.try(&.to_i?) || flags.port
    end

    private def run_ping
      host = sip_target
      target = "#{host}:#{sip_port}"
      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::PHONE} Testing OPTIONS ping to #{VoIPAppz::Colors.cyan(target)}...")
      response = VoIPAppz::SIP.options(host, sip_port, domain: flags.domain)
      if response
        puts VoIPAppz::Colors.success("SIP #{response.status} #{response.reason} from #{target}")
        server = response.header?("server")
        puts VoIPAppz::Colors.dim("  server: #{server}") if server
      else
        STDERR.puts VoIPAppz::Colors.error("No SIP reply from #{target} (timeout)")
        exit 1
      end
    end

    # INVITE probe — the only level that exercises ROUTING.
    #
    # `--level ping` sends OPTIONS, which a forwarder answers locally without
    # touching the dispatcher: it stays green against a box whose routing is
    # entirely broken. This asks the box to actually decide where a call goes.
    # A whole call, not a single request: INVITE -> 200 -> ACK -> BYE.
    #
    # `--level invite` proves the proxy ACCEPTED a request. It cannot prove the
    # proxy can relay a DIALOG, which is where a forwarder's bugs live —
    # whether the ACK follows the Route set, whether the BYE reaches the far
    # side, whether the Contact rewriting survives. Those are the paths
    # record_route() exists for, and one request never touches them.
    # NOT `run_call` — that name is already taken by the sipexer-backed load
    # helper below, and Crystal resolved the bare call to THAT one, so this
    # method was silently never reached.
    private def run_dialog
      target = "#{sip_target}:#{sip_port}"
      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::PHONE} Placing a call via #{VoIPAppz::Colors.cyan(target)}...")

      result = VoIPAppz::SIP.call(sip_target, sip_port,
        user: flags.user,
        domain: flags.domain,
        # Credentials only when a password was given — otherwise the caller is
        # anonymous and a challenge is simply reported, not answered.
        username: flags.password.empty? ? nil : flags.user,
        password: flags.password.empty? ? nil : flags.password)

      result.provisional.each { |r| puts VoIPAppz::Colors.dim("  #{r.status} #{r.reason}") }

      final = result.final
      unless final
        STDERR.puts VoIPAppz::Colors.error("No final response from #{target}#{result.error ? " (#{result.error})" : ""}")
        exit 1
      end

      unless result.answered?
        STDERR.puts VoIPAppz::Colors.error("SIP #{final.status} #{final.reason} — the call was not answered")
        exit 1
      end

      puts VoIPAppz::Colors.success("SIP #{final.status} #{final.reason} — answered")
      puts VoIPAppz::Colors.dim("  ringing:      #{result.ringing? ? "yes" : "no (answered without 180/183)"}")
      puts VoIPAppz::Colors.dim("  ACK sent:     #{result.ack_sent}")
      # A BYE that goes unanswered means the in-dialog path is broken even
      # though setup worked — exactly the failure a single INVITE hides.
      if bye = result.bye
        puts VoIPAppz::Colors.success("  BYE #{bye.status} #{bye.reason} — dialog torn down")
      else
        STDERR.puts VoIPAppz::Colors.error("  BYE got no answer — the in-dialog path is broken")
        exit 1
      end
    end

    private def run_invite
      target = "#{sip_target}:#{sip_port}"
      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::PHONE} Testing INVITE routing via #{VoIPAppz::Colors.cyan(target)}...")
      response = VoIPAppz::SIP.invite(sip_target, sip_port, domain: flags.domain)
      unless response
        STDERR.puts VoIPAppz::Colors.error("No SIP reply from #{target} (timeout)")
        exit 1
      end
      case response.status
      when 100, 180, 183, 200
        # Provisional or answered: the request was accepted and forwarded.
        puts VoIPAppz::Colors.success("SIP #{response.status} #{response.reason} — routed")
      when 404
        # Understood, but nowhere to send it: an empty or unreachable
        # dispatcher set. Fail-closed and diagnosable, not a transport problem.
        STDERR.puts VoIPAppz::Colors.error("SIP 404 #{response.reason} — no destination (dispatcher empty or all destinations inactive)")
        STDERR.puts VoIPAppz::Colors.dim("  seed it with `voipappz sbc ingress sync`, then check `voipappz sbc ingress list`")
        exit 1
      else
        STDERR.puts VoIPAppz::Colors.error("SIP #{response.status} #{response.reason}")
        exit 1
      end
    end

    private def run_register
      user = flags.user
      aor = "#{user}@#{flags.domain}"
      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::PHONE} Testing REGISTER for #{VoIPAppz::Colors.cyan(aor)}...")
      password = flags.password.empty? ? (ENV["VA_TEST_SIP_PASSWORD"]? || "loadtest") : flags.password
      response = VoIPAppz::SIP.register(sip_target, sip_port, user, password,
        domain: flags.domain)
      unless response
        STDERR.puts VoIPAppz::Colors.error("No SIP reply from #{sip_target}:#{sip_port} (timeout)")
        exit 1
      end
      if response.status == 200
        puts VoIPAppz::Colors.success("REGISTER 200 OK — #{aor} registered")
      elsif flags.password.empty? && ENV["VA_TEST_SIP_PASSWORD"]?.nil? && [401, 407].includes?(response.status)
        # In an unprovisioned CI node there is intentionally no real phone
        # password.  A digest challenge is still a successful REGISTER
        # transaction: it proves Kamailio received, parsed, and challenged the
        # request.  When a password is supplied, 200 remains mandatory.
        puts VoIPAppz::Colors.success("REGISTER #{response.status} #{response.reason} — registrar challenge received")
      else
        puts VoIPAppz::Colors.error("REGISTER #{response.status} #{response.reason} — registration failed")
        exit 1
      end
    end

    private def run_call(duration : Int32 = 30)
      ensure_sipexer!
      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::PHONE} Testing INVITE call for #{duration}s...")
      run_sipexer(["-invite", "-fuser", "loadtest", "-tuser", "echo",
                   "-sw", (duration * 1000).to_s, "-vl", "1",
                   "udp:#{sip_target}:#{sip_port}"])
    end

    private def run_load(calls : Int32 = 10, duration : Int32 = 30)
      ensure_sipexer!
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::BOLT} Load Test: #{calls} calls \u00D7 #{duration}s")
      puts ""

      success = 0
      calls.times do |i|
        stdout = IO::Memory.new
        process = Process.new(
          "sipexer",
          ["-invite", "-fuser", "loadtest#{i + 1}", "-tuser", "echo",
           "-sw", (duration * 1000).to_s, "-vl", "0",
           "udp:#{sip_target}:#{sip_port}"],
          output: stdout,
          error: Process::Redirect::Close,
        )
        status = process.wait
        success += 1 if status.success?
      end

      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::BOLT} Load test completed: #{success}/#{calls} successful calls")
    end

    private def run_stress(calls : Int32 = 50, duration : Int32 = 30)
      ensure_sipexer!
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::BOLT} Stress Test: #{calls} registrations")
      puts ""

      success = 0
      calls.times do |i|
        process = Process.new(
          "sipexer",
          ["-register", "-fuser", "stress#{i + 1}", "-tuser", "stress#{i + 1}",
           "-ex", "60", "-vl", "0",
           "udp:#{sip_target}:#{sip_port}"],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )
        status = process.wait
        success += 1 if status.success?
        if (i + 1) % 10 == 0
          puts "  #{VoIPAppz::Colors.progress_bar(i + 1, calls, 25)}"
        end
      end

      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::BOLT} Stress test completed: #{success}/#{calls} successful registrations")
    end

    private def sipexer_available? : Bool
      Process.find_executable("sipexer") != nil
    end

    private def ensure_sipexer!
      unless sipexer_available?
        STDERR.puts VoIPAppz::Colors.error("sipexer not found. Install it or run 'voipappz setup'")
        exit 1
      end
    end

    # `voipappz test mail --email <account>`
    #
    # An account must be able to FINISH auth: the OTP mail the API sends has to
    # reach a mailbox. Out of the box that mailbox is the local mailpit, and for
    # months it never did — see helpers/mailbox.cr for how silent that was.
    #
    # The real chain, not a stub: the endpoint, the Sidekiq job embedded in
    # Puma, SmtpSettings, net-smtp, and mailpit's AUTH handling (net-smtp sends
    # AUTH even for an empty username; mailpit must accept it).
    class AuthMail < Admiral::Command
      define_help description: "An OTP mail the API sends must reach the mailbox"

      define_flag email : String, description: "The ENABLED account to request a code for", default: ""
      define_flag wait : Int32, description: "Seconds to wait for the mail", default: 30

      def run
        email = flags.email.presence || ENV["EMAIL"]?.presence
        unless email
          STDERR.puts VoIPAppz::Colors.red("--email is required: the enabled account to request a code for")
          exit 2
        end

        mail = VoIPAppz::Mailbox.mail
        unless VoIPAppz::Mailbox.get("#{mail}/api/v1/info")
          STDERR.puts VoIPAppz::Colors.error("nothing answers at #{mail}/api/v1/info")
          exit 1
        end
        before = VoIPAppz::Mailbox.count(email)
        puts VoIPAppz::Colors.success("mailbox answers at #{mail} (#{before} already for #{email})")

        # Always 200 — a silent 200 is the point, so only the mailbox can say
        # whether it worked.
        status, body = VoIPAppz::Mailbox.post("/auth/forget_password", {"email" => email})
        unless status == 200
          STDERR.puts VoIPAppz::Colors.error("POST /auth/forget_password answered #{status}: #{body}")
          exit 1
        end
        puts VoIPAppz::Colors.success("API accepted a password-reset request for #{email}")

        deadline = Time.monotonic + flags.wait.seconds
        loop do
          if VoIPAppz::Mailbox.count(email) > before
            subject = VoIPAppz::Mailbox.newest(email).try(&.["Subject"]?.try(&.as_s?)) || ""
            puts VoIPAppz::Colors.success("the code reached the mailbox: #{subject.inspect}")
            return
          end
          break if Time.monotonic >= deadline
          sleep 1.second
        end

        STDERR.puts VoIPAppz::Colors.error(
          "the API said otp_sent but #{mail} holds no new mail for #{email} within #{flags.wait}s")
        STDERR.puts VoIPAppz::Colors.dim("  Is #{email} an ENABLED account? Then: docker compose logs web | grep -i smtp")
        exit 1
      end
    end

    # `voipappz test login --email <a> --password <p>`
    #
    # The whole front door, through the running stack: password -> OTP mail ->
    # /auth/otp/verify -> session. The mail leg is `test mail`'s business; this
    # is the only check that proves the session comes out the other end.
    class LoginFlow < Admiral::Command
      define_help description: "An account logs in end to end: password, code, session"

      define_flag email : String, description: "The account", default: ""
      define_flag password : String, description: "Its password", default: ""
      define_flag wait : Int32, description: "Seconds to wait for the code", default: 30

      SUBJECT = "login code"

      def run
        email = flags.email.presence || ENV["EMAIL"]?.presence
        password = flags.password.presence || ENV["PASSWORD"]?.presence
        unless email && password
          STDERR.puts VoIPAppz::Colors.red("--email and --password are required")
          exit 2
        end

        before = VoIPAppz::Mailbox.count(email, SUBJECT)
        status, body = VoIPAppz::Mailbox.post("/auth/login", {"email" => email, "password" => password})
        temp = field(body, "temp_token")
        unless temp
          STDERR.puts VoIPAppz::Colors.error("login did not issue an OTP (#{status}): #{body}")
          exit 1
        end
        puts VoIPAppz::Colors.success("password accepted, OTP issued")

        code = await_code(email, before)
        unless code
          STDERR.puts VoIPAppz::Colors.error(
            "no login code reached #{VoIPAppz::Mailbox.mail} for #{email} within #{flags.wait}s")
          exit 1
        end
        puts VoIPAppz::Colors.success("login code reached the mailbox")

        status, body = VoIPAppz::Mailbox.post("/auth/otp/verify", {"temp_token" => temp, "code" => code})
        unless body =~ /"(access|token|jwt)"/
          STDERR.puts VoIPAppz::Colors.error("OTP verify did not return a session (#{status}): #{body}")
          exit 1
        end
        puts VoIPAppz::Colors.success("OTP verified, session issued")
      end

      private def await_code(email : String, before : Int32) : String?
        deadline = Time.monotonic + flags.wait.seconds
        loop do
          if VoIPAppz::Mailbox.count(email, SUBJECT) > before
            if id = VoIPAppz::Mailbox.newest(email, SUBJECT).try(&.["ID"]?.try(&.as_s?))
              body = VoIPAppz::Mailbox.get("#{VoIPAppz::Mailbox.mail}/api/v1/message/#{id}")
              if body && (m = body.match(/login code is: (\d{6})/))
                return m[1]
              end
            end
          end
          return nil if Time.monotonic >= deadline
          sleep 1.second
        end
      end

      # The API answers JSON; this wants one string field out of it without
      # caring about the rest of the shape.
      private def field(body : String, name : String) : String?
        JSON.parse(body)[name]?.try(&.as_s?)
      rescue
        nil
      end
    end

    # `voipappz test scenario <manifest.yml>`
    #
    # Compiles a sippy_cup-style YAML manifest into a SIPp scenario plus its RTP
    # media, then runs it. The compiler is helpers/sipp — nothing here parses
    # anything, so `--compile-only` and a real run share one code path.
    class SippScenario < Admiral::Command
      define_help description: "Compile and run a SIPp scenario from a YAML manifest"

      # Optional: with no argument the command lists what it carries, the way
      # `voipappz shell` lists its services rather than failing on an argument
      # the caller has no way to guess.
      define_argument manifest : String,
        description: "A built-in scenario name, or a path to a scenario YAML"

      # out_dir, not out, with `long:` keeping the flag itself `--out`: `out` is
      # a Crystal keyword (C-binding output parameters), so `define_flag out`
      # fails to parse with "expecting variable or instance variable after out".
      # Same trap helpers/runner.cr records for `return out`.
      define_flag out_dir : String,
        description: "Directory to write the compiled scenario and media into",
        default: "",
        short: o,
        long: "out"
      define_flag compile_only : Bool,
        description: "Compile the scenario and media, then stop",
        default: false
      define_flag dry_run : Bool,
        description: "Print the SIPp command that would run, then stop",
        default: false
      define_flag destination : String,
        description: "Override the manifest's destination (host[:port])",
        default: "",
        short: d
      define_flag source : String,
        description: "Override the manifest's source (the address SIPp binds)",
        default: ""
      define_flag to : String,
        description: "Override who to call \u2014 the extension the node answers on",
        default: "",
        short: t
      define_flag calls : Int32,
        description: "Override number_of_calls",
        default: 0,
        short: c
      define_flag cps : Float64,
        description: "Override calls_per_second",
        default: 0.0
      define_flag concurrent : Int32,
        description: "Override max_concurrent",
        default: 0

      def run
        name = arguments.manifest
        unless name
          list_builtins
          return
        end

        options = load_options(name)
        apply_overrides options

        directory = flags.out_dir.empty? ? Dir.current : File.expand_path(flags.out_dir)
        scenario_path, pcap_path, uas = compile(options, directory)

        puts VoIPAppz::Colors.success("scenario  #{scenario_path}")
        puts VoIPAppz::Colors.success("media     #{pcap_path}") if pcap_path
        return if flags.compile_only

        args = begin
          VoIPAppz::Sipp::Runner.sipp_args(options, scenario_path,
            require_destination: !uas, interactive: STDIN.tty?)
        rescue e : VoIPAppz::Sipp::Error
          STDERR.puts VoIPAppz::Colors.error(e.message.to_s)
          STDERR.puts VoIPAppz::Colors.dim("  pass --destination, or set `destination:` in the manifest")
          # Deliberately NOT defaulted from va.yaml. That file is the node's, it
          # is generated by the API per node, and the CLI is losing its readers
          # of it (docs/next-cli-boundary.md). A scenario names its own target.
          exit 1
        end

        command, argv = invocation(args, !pcap_path.nil?)

        if flags.dry_run
          puts VoIPAppz::Colors.dim("#{command} #{argv.join(" ")}")
          return
        end

        puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::BOLT} #{command} #{argv.join(" ")}")
        puts ""
        status = Process.run(command, argv,
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit)

        # A signalled process HAS no exit code, and asking for one raises.
        # SIPp gets killed often enough — a timeout in CI, an operator's Ctrl-C
        # — that reading it unguarded turns a stopped test into a crash.
        unless status.normal_exit?
          STDERR.puts VoIPAppz::Colors.error("SIPp was killed (#{status.exit_reason})")
          exit 1
        end

        code = status.exit_code
        if message = VoIPAppz::Sipp::Runner.exit_message(code)
          # A failed call is a test result; anything else is a broken run. Both
          # exit non-zero, but only one of them is about the scenario.
          reporter = VoIPAppz::Sipp::Runner.calls_failed?(code) ? VoIPAppz::Colors.warning(message) : VoIPAppz::Colors.error(message)
          STDERR.puts reporter
          exit code
        end

        puts VoIPAppz::Colors.success("scenario completed \u2014 every call succeeded")
      end

      private def list_builtins : Nil
        puts VoIPAppz::Colors.bold("Built-in scenarios:")
        VoIPAppz::Sipp::Builtin.names.each do |name|
          puts "  #{VoIPAppz::Colors.cyan(name.ljust(20))} #{VoIPAppz::Sipp::Builtin.summary(name)}"
        end
        puts ""
        puts VoIPAppz::Colors.dim("  voipappz test scenario call --to 1001")
        puts VoIPAppz::Colors.dim("  voipappz test scenario ./my-scenario.yml")
      end

      # A built-in name first, then a path. The binary carries its own examples,
      # so a node with no checkout can still run one.
      private def load_options(name : String) : VoIPAppz::Sipp::Options
        if manifest = VoIPAppz::Sipp::Builtin::SCENARIOS[name]?
          options = VoIPAppz::Sipp::Options.from_manifest(manifest)
          options.given_name ||= name
          return options
        end

        unless File.exists?(name)
          STDERR.puts VoIPAppz::Colors.error("no built-in scenario or file named `#{name}`")
          STDERR.puts VoIPAppz::Colors.dim("  built in: #{VoIPAppz::Sipp::Builtin.names.join(", ")}")
          exit 1
        end

        options = VoIPAppz::Sipp::Options.from_manifest(File.read(name))
        options.given_name ||= File.basename(name).sub(/\.ya?ml$/, "")
        options
      rescue e : YAML::ParseException
        STDERR.puts VoIPAppz::Colors.error("#{name} is not valid YAML: #{e.message}")
        exit 1
      end

      # Flags win over the manifest, so one manifest can be aimed at a lab box
      # or a node without being edited.
      private def apply_overrides(options : VoIPAppz::Sipp::Options) : Nil
        options.destination = flags.destination unless flags.destination.empty?
        options.source = flags.source unless flags.source.empty?
        # `to` has to land before the steps are built: it is interpolated into
        # the INVITE's request URI, not passed to SIPp as a flag.
        options.to = flags.to unless flags.to.empty?
        options.number_of_calls = flags.calls if flags.calls > 0
        options.calls_per_second = flags.cps if flags.cps > 0
        options.max_concurrent = flags.concurrent if flags.concurrent > 0
      end

      # Either compiles the manifest's steps, or stages a hand-written SIPp
      # scenario the manifest points at. Both end up in one directory, which is
      # what the container mounts.
      private def compile(options : VoIPAppz::Sipp::Options, directory : String) : {String, String?, Bool}
        if raw = options.scenario
          Dir.mkdir_p directory
          scenario_path = File.join(directory, File.basename(raw))
          File.copy raw, scenario_path unless File.expand_path(raw) == scenario_path
          pcap_path = options.media.try do |media|
            target = File.join(directory, File.basename(media))
            File.copy media, target unless File.expand_path(media) == target
            target
          end
          # A hand-written scenario is taken at its word: it names a
          # destination or SIPp says so itself.
          return {scenario_path, pcap_path, false}
        end

        steps = options.steps
        unless steps
          STDERR.puts VoIPAppz::Colors.error("the manifest has neither `steps` nor `scenario`")
          exit 1
        end

        scenario = VoIPAppz::Sipp::Scenario.new(options)
        scenario.build steps
        unless scenario.valid?
          STDERR.puts VoIPAppz::Colors.error("the manifest has #{scenario.errors.size} bad step(s):")
          scenario.errors.each { |error| STDERR.puts VoIPAppz::Colors.error("  #{error}") }
          exit 1
        end
        scenario_path, pcap_path = scenario.compile!(directory)
        {scenario_path, pcap_path, scenario.uas?}
      rescue e : VoIPAppz::Sipp::Error
        STDERR.puts VoIPAppz::Colors.error(e.message.to_s)
        exit 1
      end

      # An installed sipp wins; otherwise the pinned release binary is fetched
      # into .cache once, the same way scripts/test-ingress.sh gets sipexer.
      # Nothing here can silently skip: with no SIPp the run fails and says so.
      private def invocation(args : Array(String), has_media : Bool) : {String, Array(String)}
        root = VoIPAppz::Project.root
        sipp = VoIPAppz::Sipp::Runner.local_sipp || VoIPAppz::Sipp::Runner.cached_sipp(root)

        unless sipp
          # A dry run reports the command; it does not download anything to
          # print a line.
          if flags.dry_run
            sipp = VoIPAppz::Sipp::Runner.cache_path(root)
          else
            puts VoIPAppz::Colors.info("no sipp on PATH \u2014 fetching SIPp #{VoIPAppz::Sipp::Runner::SIPP_VERSION}")
            begin
              sipp = VoIPAppz::Sipp::Runner.fetch!(root)
            rescue e : VoIPAppz::Sipp::Error
              STDERR.puts VoIPAppz::Colors.error(e.message.to_s)
              exit 1
            end
          end
        end

        # Replaying a pcap needs a raw socket, which needs root.
        if VoIPAppz::Sipp::Runner.needs_sudo?(has_media)
          unless VoIPAppz::Sipp::Runner.sudo_available?
            STDERR.puts VoIPAppz::Colors.error("replaying media needs root \u2014 SIPp opens a raw socket for it")
            STDERR.puts VoIPAppz::Colors.dim("  run as root, or allow passwordless sudo; --compile-only skips the run entirely")
            exit 1
          end
          return {"sudo", [sipp] + args}
        end
        {sipp, args}
      end
    end

    private def run_sipexer(args : Array(String))
      process = Process.new(
        "sipexer",
        args,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      status = process.wait
      if status.success?
        puts VoIPAppz::Colors.success("Test passed")
      else
        puts VoIPAppz::Colors.error("Test failed")
      end
    end
  end
end
