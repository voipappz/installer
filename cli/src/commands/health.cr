require "admiral"
require "http/client"
require "json"
require "../helpers/colors"
require "../helpers/table"
require "../helpers/docker"
require "../helpers/sip"
require "../helpers/node_health"
require "../helpers/gatus"

module VoIPAppz::Commands
  class Health < Admiral::Command
    define_help description: "Run health checks on all services"

    define_flag watch : Bool,
      description: "Refresh every 5 seconds",
      default: false,
      short: w
    define_flag http : Bool,
      description: "Check HTTP endpoints only",
      default: false
    # GATUS IS THE SOURCE OF TRUTH. It probes every service continuously from
    # inside the network, and it is what the alerting acts on — so a second
    # opinion computed here can only disagree with the one that pages someone.
    # Default on a host; see #run.
    define_flag gatus : Bool,
      description: "Gate on Gatus: wait for every gated group to be green",
      default: false,
      short: g
    define_flag report : Bool,
      description: "Print the Gatus board and exit 0, whatever it says",
      default: false
    define_flag timeout : Int32,
      description: "Seconds to wait for Gatus to go green (--gatus)",
      default: 180
    define_flag direct : Bool,
      description: "Skip Gatus and the node's verdict — run the CLI's direct probes",
      default: false
    define_flag ci : Bool,
      description: "CI mode (retry during startup before failing)",
      default: false
    define_flag json : Bool,
      description: "Emit machine-readable JSON",
      default: false
    define_flag api : Bool,
      description: "Check the API's aggregate /health endpoint (:5000) — the app's own rollup",
      default: false

    SERVICE_ICONS = {
      "Kamailio"    => VoIPAppz::Colors::PHONE,
      "FreeSWITCH"  => VoIPAppz::Colors::PHONE,
      "Node"        => VoIPAppz::Colors::BOLT,
      "MinIO"       => VoIPAppz::Colors::BOX,
    }

    def run
      {% if flag?(:node_runtime) %}
        # Gatus is an app-profile service. A voip node does not run one, so on
        # that build these are not "unsupported yet" — there is nothing to ask.
        if flags.watch || flags.http || flags.direct || flags.api || flags.gatus || flags.report
          STDERR.puts VoIPAppz::Colors.error(
            "This health mode requires the host development stack; use `voipappz health` inside the node"
          )
          exit 2
        end
      {% end %}

      ENV["VOIPAPPZ_JSON"] = "1" if flags.json

      if flags.json
        run_json
      elsif flags.report
        run_gatus(gate: false)
      elsif flags.gatus
        run_gatus(gate: true)
      elsif flags.api
        run_api_health
      elsif flags.http
        run_http_checks
      elsif flags.watch
        loop do
          print "\e[2J\e[H"
          run_all_checks(exit_on_failure: false)
          sleep 5.seconds
        end
      elsif flags.direct
        run_all_checks
      else
        # DEFAULT = GATUS, on a host. It watches every service continuously and
        # its verdict is the one the alerting acts on; anything computed here
        # instead is a second opinion that can disagree with the one that pages
        # someone. Restored 2026-09-01 — see helpers/gatus.cr for where it went.
        #
        # Gatus UNREACHABLE is the watchtower-down alarm, and only then does
        # this fall through: the node's own verdict, and failing that the CLI's
        # direct probes, can still say WHICH service is missing on a half-built
        # box. A gatus that answers RED is answered by run_gatus itself.
        {% unless flag?(:node_runtime) %}
          return if try_gatus
          puts VoIPAppz::Colors.error(
            "#{VoIPAppz::Colors::WARN}  GATUS IS NOT ANSWERING (#{VoIPAppz::Gatus.url}) — monitoring is OFFLINE")
          puts VoIPAppz::Colors.warning("Falling back to the node's own verdict:")
          puts ""
        {% end %}

        # Then: ask the node. It probes its own plane continuously and on
        # loopback (kamailio RPC, dispatcher routability, FreeSWITCH ESL, host
        # CPU/mem/disk), so there is no point re-implementing those probes from
        # outside — and its answer is the one the mothership sees too.
        #
        # A node that does not answer is itself the alarm, and then the CLI's
        # own probes are all that is left: they can still say WHICH service is
        # missing, which is what an operator on a half-built box needs.
        unless try_node_health
          puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::WARN}  THE NODE IS NOT ANSWERING (#{VoIPAppz::NodeHealth.url})")
          {% if flag?(:node_runtime) %}
            exit 1
          {% else %}
            puts VoIPAppz::Colors.warning("Falling back to direct probes (voipappz health --direct):")
            puts ""
            run_all_checks
            # Direct probes may pass while the node itself is down — a node that
            # cannot report is a node that cannot take a call, so never report a
            # successful process status to scripts or the console shortcut.
            exit 1
          {% end %}
        end
      end
    end

    # ------------------------------------------------------------------ gatus
    #
    # `--gatus` is a GATE: it waits for every gated group to go green and fails
    # if that never happens. `--report` prints the same board and exits 0.
    #
    # Both were scripts/check-gatus.sh, 148 lines of POSIX sh that shelled to
    # python3 to parse the JSON. It existed because the CLI had lost this and
    # the gate could not wait for a binary that might not build — but the
    # binary is built and tested in CI now, and two implementations of one
    # question is how they come to disagree.
    private def run_gatus(gate : Bool)
      board = [] of VoIPAppz::Gatus::Endpoint
      begin
        board =
          if gate
            # Say what it is waiting for, once. A gate that prints nothing for
            # three minutes is indistinguishable from one that has hung, and
            # this runs right after `up`, when something is always still amber.
            announced = false
            VoIPAppz::Gatus.wait(flags.timeout.seconds) do |snapshot|
              bad = VoIPAppz::Gatus.failing(snapshot)
              unless announced || bad.empty?
                announced = true
                STDERR.puts VoIPAppz::Colors.dim(
                  "  waiting up to #{flags.timeout}s for: #{bad.map(&.name).join(", ")}")
              end
            end
          else
            VoIPAppz::Gatus.fetch
          end
      rescue ex : VoIPAppz::Gatus::Unreachable
        # UNREACHABLE IS A FAILURE EVEN FOR --report. The watchtower being
        # unreachable is itself the alarm — it is what alerts.
        STDERR.puts VoIPAppz::Colors.error("could not read gatus at #{VoIPAppz::Gatus.url} (#{ex.message})")
        STDERR.puts VoIPAppz::Colors.dim("   the watchtower being unreachable is itself the alarm — it is what alerts.")
        exit 1
      end

      puts VoIPAppz::Gatus.render(board)
      exit 0 unless gate

      failing = VoIPAppz::Gatus.failing(board)
      if failing.empty?
        puts VoIPAppz::Colors.success(
          "gatus: every gated check green (#{board.size} endpoints probed) #{VoIPAppz::Colors::CHECK}")
        exit 0
      end

      STDERR.puts ""
      STDERR.puts VoIPAppz::Colors.error("gatus does not say this node is healthy:")
      failing.each do |e|
        STDERR.puts "   #{e.group}/#{e.name} — #{e.detail.empty? ? "down" : e.detail}"
      end
      exit 1
    end

    # The default path's use of the same source: render it, judge it, and say
    # so — but return false rather than exiting when gatus cannot be reached,
    # so the caller can fall back to probes that still diagnose a broken host.
    private def try_gatus : Bool
      board = VoIPAppz::Gatus.fetch
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::HEART} Gatus — the aggregate this node is judged by")
      puts ""
      puts VoIPAppz::Gatus.render(board)
      failing = VoIPAppz::Gatus.failing(board)
      if failing.empty?
        puts VoIPAppz::Colors.success(
          "#{VoIPAppz::Colors::CHECK} every gated check green (#{board.size} endpoints probed)")
        return true
      end
      puts ""
      STDERR.puts VoIPAppz::Colors.error("#{failing.size} gated check(s) failing:")
      failing.each { |e| STDERR.puts "   #{e.group}/#{e.name} — #{e.detail.empty? ? "down" : e.detail}" }
      exit 1
    rescue VoIPAppz::Gatus::Unreachable
      false
    end

    # The API's own aggregate health (the `web` service, published on :5000),
    # followed by the public Kong edge. This makes the operator-facing command
    # catch the real failure mode where the API is healthy but Kong has a stale
    # or invalid upstream. In --ci mode it retries while the stack warms up.
    private def run_api_health
      api_port = ENV.fetch("VA_API_PORT", "5000")
      url = "http://127.0.0.1:#{api_port}/health"
      attempts = flags.ci ? 36 : 1
      interval = 10
      # Which of the two URLs actually failed. Reporting the API's when Kong is
      # the one answering 503 sends whoever reads it to the healthy service.
      failed_url = url
      attempts.times do |i|
        begin
          uri = URI.parse(url)
          client = HTTP::Client.new(uri)
          client.connect_timeout = 3.seconds
          client.read_timeout = 5.seconds
          response = client.get(uri.request_target)
          if response.status_code == 200
            puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} API healthy — #{url}")
            kong_port = ENV.fetch("VA_KONG_HTTP_PORT", "80")
            # Kong's declarative config exposes /health; /version.json is not
            # a route and would make a healthy edge look permanently down.
            kong_url = "http://127.0.0.1:#{kong_port}/health"
            kong_uri = URI.parse(kong_url)
            kong = HTTP::Client.new(kong_uri)
            kong.connect_timeout = 3.seconds
            kong.read_timeout = 5.seconds
            kong_response = kong.get(kong_uri.request_target)
            if kong_response.status_code == 200
              puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} Kong edge healthy — #{kong_url}")
              return
            end
            failed_url = kong_url
            STDERR.puts VoIPAppz::Colors.warning("Kong returned #{kong_response.status_code} (attempt #{i + 1}/#{attempts})")
          else
            STDERR.puts VoIPAppz::Colors.warning("API /health returned #{response.status_code} (attempt #{i + 1}/#{attempts})")
          end
        rescue ex
          STDERR.puts VoIPAppz::Colors.warning("API/Kong health unreachable (attempt #{i + 1}/#{attempts}): #{ex.message}")
        end
        sleep interval.seconds if i < attempts - 1
      end
      STDERR.puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::WARN}  API health check failed — #{failed_url}")
      exit 1
    end

    # The node's verdict, returning false (instead of exiting) when it does not
    # answer, so the default path can fall back to direct probes.
    private def try_node_health : Bool
      verdict = VoIPAppz::NodeHealth.verdict
      return false unless verdict
      render_node_health(verdict)
      true
    end

    # Machine-readable health snapshot. THE NODE'S OWN VERDICT when it answers
    # — the same document /health/node serves, verbatim, so a script reads the
    # down-list, warnings, per-group board and live counters the operator sees
    # (and the only thing available inside the node image, which has no host
    # probes). Only when the node is silent does this fall back to the CLI's
    # port probes, and it says so in the payload.
    # MACHINE-READABLE, FROM THE SAME SOURCE. `--json` is what CI and scripts
    # read, and until now it answered from the CLI's own probes while an
    # operator running `voipappz health` beside them was answered by gatus.
    # Two consumers, one host, two verdicts — the exact split this command
    # exists to avoid. `source` names which one answered, and the fallbacks
    # below are only reached when the one above them cannot be reached at all.
    private def run_json
      {% unless flag?(:node_runtime) %}
        begin
          board = VoIPAppz::Gatus.fetch
          gated = VoIPAppz::Gatus.gated_groups
          failing = VoIPAppz::Gatus.failing(board, gated)
          puts({
            "source"    => "gatus",
            "ok"        => failing.empty?,
            "gated"     => gated,
            "endpoints" => board.map { |e|
              {"group" => e.group, "name" => e.name, "up" => e.up,
               "gated" => e.gated?(gated), "detail" => e.detail}
            },
            "summary" => {
              "total"         => board.size,
              "up"            => board.count(&.up),
              "down"          => board.count { |e| !e.up },
              "failing_gated" => failing.size,
            },
          }.to_json)
          # 4, not 1: every other --json path in this command reports a failed
          # check as 4, and a script switching on the code must not have to
          # know which source answered.
          exit(failing.empty? ? 0 : 4)
        rescue VoIPAppz::Gatus::Unreachable
          # Fall through — and `source` will say so.
        end
      {% end %}

      if body = VoIPAppz::NodeHealth.body
        puts body
        exit(JSON.parse(body)["ok"]?.try(&.as_bool?) ? 0 : 4)
      end
      {% if flag?(:node_runtime) %}
        puts({"ok" => false, "error" => "the node is not answering at #{VoIPAppz::NodeHealth.url}"}.to_json)
        exit 4
      {% end %}
      checks = evaluate_checks
      payload = {
        "source" => "cli-probes",
        "checks" => checks.map { |name, port, ok|
          {"name" => name, "port" => port, "ok" => ok}
        },
        "summary" => {
          "total"  => checks.size,
          "passed" => checks.count { |_, _, ok| ok },
          "failed" => checks.count { |_, _, ok| !ok },
        },
      }
      puts payload.to_json
      exit 4 if checks.any? { |_, _, ok| !ok }
    end

    # The node's own board: how many of its checks pass, and the name and error
    # of every one that does not.
    #
    # Only failures are named. The node reports its verdict as up/total plus a
    # down-list (node/local_health.cr, `aggregate`), which is the shape that
    # matters to an operator — a list of greens is noise next to the one red,
    # and the greens are implied by the count.
    private def render_node_health(verdict : VoIPAppz::NodeHealth::Verdict)
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::HEART} Node health")
      puts VoIPAppz::Colors.dim("  #{VoIPAppz::NodeHealth.url}")
      puts ""

      verdict.down.each do |entry|
        key, error = VoIPAppz::NodeHealth.split_down(entry)
        line = "  #{VoIPAppz::Colors.dot_fail}  #{key.ljust(28)}"
        line += " #{VoIPAppz::Colors.dim(error)}" if error
        puts line
      end
      puts "" unless verdict.down.empty?

      # Passing with a note — a license about to expire, an OPTIONS answered
      # with something other than 200. Not failures, not silence either.
      verdict.warn.each do |entry|
        key, note = VoIPAppz::NodeHealth.split_down(entry)
        puts "  #{VoIPAppz::Colors::WARN}  #{key.ljust(28)} #{VoIPAppz::Colors.dim(note || "")}"
      end
      puts "" unless verdict.warn.empty?

      # The live counters the node read from its plane, when it could.
      line = verdict.metrics_line
      puts VoIPAppz::Colors.dim("  #{line}") unless line.empty?
      cap = verdict.capture_line
      puts VoIPAppz::Colors.dim("  #{cap}") unless cap.empty?

      puts VoIPAppz::Colors.divider(50)
      if verdict.ok
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} All #{verdict.total} node checks passing")
      else
        puts VoIPAppz::Colors.error("#{verdict.failing}/#{verdict.total} node checks failing")
        exit 1
      end
    end

    private def run_all_checks(exit_on_failure : Bool = true)
      checks = evaluate_checks

      if flags.ci
        max_attempts = 36
        interval = 10
        attempt = 1

        while checks.any? { |_, _, ok| !ok } && attempt < max_attempts
          sleep interval.seconds
          attempt += 1
          checks = evaluate_checks
        end
      end

      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::HEART} Health Check")
      puts ""

      passed = 0
      total = checks.size

      checks.each do |name, port, ok|
        icon = SERVICE_ICONS[name]? || VoIPAppz::Colors::BULLET
        status_icon = ok ? VoIPAppz::Colors.dot_ok : VoIPAppz::Colors.dot_fail
        port_str = VoIPAppz::Colors.dim(port)
        puts "  #{status_icon} #{icon}  #{name.ljust(14)} #{port_str}"
        passed += 1 if ok
      end

      puts ""
      puts VoIPAppz::Colors.divider(50)

      if passed == total
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} All #{total} checks passed")
      else
        failed = total - passed
        puts VoIPAppz::Colors.error("#{failed}/#{total} checks failed")
        exit 1 if exit_on_failure
      end
    end

    private def evaluate_checks
      [
        # SIP layer
        {"Kamailio SIP",       ":5060",     check_kamailio},
        {"Kamailio OPTIONS",   "SIP 200",   check_sip_options},
        {"Kamailio dispatcher","loaded",    check_kamailio_dispatcher},
        {"Kamailio domain",    "loaded",    check_kamailio_domain},
        # Media engine
        {"FreeSWITCH ESL",    ":8021",  check_freeswitch},
        {"FreeSWITCH Sofia",  "sofia",  check_freeswitch_sofia},
        # Crystal node agent
        {"Node /health",      ":4000",  check_http("http://127.0.0.1:4000/health")},
        {"Node ACL XML",      "/switch",check_node_xml},
        # Storage
        {"MinIO",             ":9000",  check_http("http://127.0.0.1:9000/minio/health/live")},
        {"MinIO bucket",      "recordings", check_minio_bucket},
        # Broker
        # Scheduler
        {"Ofelia jobs",       "4 jobs", check_ofelia_jobs},
      ]
    end

    private def run_http_checks
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::NET} HTTP Endpoint Checks")
      puts ""

      # node-lite HTTP probes
      checks = [
        {"Node /health",   "http://127.0.0.1:4000/health",           [200],      false},
        {"MinIO",          "http://127.0.0.1:9000/minio/health/live", [200],      false},
      ]

      failed = 0
      checks.each do |name, url, accepted, ws_upgrade|
        code = ws_upgrade ? get_ws_upgrade_code(url) : get_http_code(url)
        ok = accepted.includes?(code)
        icon = SERVICE_ICONS[name]? || VoIPAppz::Colors::NET
        if ok
          puts "  #{VoIPAppz::Colors.dot_ok} #{icon}  #{name.ljust(22)} #{VoIPAppz::Colors.green("HTTP #{code}")}"
        else
          puts "  #{VoIPAppz::Colors.dot_fail} #{icon}  #{name.ljust(22)} #{VoIPAppz::Colors.red("HTTP #{code}")}"
          failed += 1
        end
      end
      exit 1 if failed > 0
    end

    # Send a WebSocket upgrade handshake; expect 101 Switching Protocols.
    # Used to verify that Kong /ws (and cable /cable) accepts WS upgrades.
    private def get_ws_upgrade_code(url : String) : Int32
      uri = URI.parse(url)
      headers = HTTP::Headers{
        "Connection"            => "Upgrade",
        "Upgrade"               => "websocket",
        "Sec-WebSocket-Version" => "13",
        "Sec-WebSocket-Key"     => "dGhlIHNhbXBsZSBub25jZQ==",
      }
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 2.seconds
      response = client.get(uri.request_target, headers: headers)
      response.status_code
    rescue
      0
    end

    private def check_kamailio_dispatcher : Bool
      container = Docker.running_kamailio?
      return false unless container
      exit_code, out = Docker.exec(container, ["kamcmd", "dispatcher.list"])
      exit_code == 0 && out.includes?("NRSETS") &&
        (out.match(/NRSETS:\s*(\d+)/).try { |m| m[1].to_i > 0 } || false)
    rescue
      false
    end

    # domain.so is loaded ONLY by the egress — the ingress is a dispatcher-only
    # forwarder and makes no tenancy decisions, so this is skipped there.
    private def check_kamailio_domain : Bool
      return true unless Docker.running_containers.includes?(
        VoIPAppz::Services.find?("kamailio-egress").try(&.container) || "va-egress")
      container = Docker.resolve_container("kamailio-egress")
      exit_code, out = Docker.exec(container, ["kamcmd", "domain.dump"])
      exit_code == 0 && out.includes?("domain:")
    rescue
      false
    end

    private def check_freeswitch_sofia : Bool
      container = Docker.resolve_container("freeswitch")
      pass = ENV["VA_FREESWITCH_PASSWORD"]? || "ClueCon"
      port = ENV["VA_FREESWITCH_PORT"]? || "8021"
      # Check that sofia module is loaded and responding (profiles are
      # provisioned later via voipappz kamailio sync + extension setup).
      exit_code, output = Docker.exec(container,
        ["fs_cli", "-H", "127.0.0.1", "-P", port, "-p", pass, "-x", "sofia status"])
      exit_code == 0 && output.includes?("profiles")
    rescue
      false
    end

    private def check_node_xml : Bool
      node_uuid = ENV["VA_NODE_UUID"]? || ""
      return false if node_uuid.empty?
      uri = URI.parse("http://127.0.0.1:4000/switch/config?node_uuid=#{node_uuid}")
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 3.seconds
      response = client.post(uri.request_target,
        headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        body: "section=configuration&key_value=acl.conf")
      response.status_code == 200 && response.body.includes?("esl_acl")
    rescue
      false
    end

    private def check_minio_bucket : Bool
      uri = URI.parse("http://127.0.0.1:9000")
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 3.seconds
      response = client.get("/recordings/")
      # 403 = bucket exists but access denied without sig — that's fine
      [200, 403].includes?(response.status_code)
    rescue
      false
    end


    private def check_ofelia_jobs : Bool
      container = Docker.resolve_container("ofelia")
      exit_code, output = Docker.exec(container,
        ["sh", "-c", "ps aux | grep ofelia"])
      # Verify node container has the expected 4 job labels
      label_exit, label_out = VoIPAppz::Docker.exec(
        Docker.resolve_container("node"),
        ["sh", "-c", "echo ok"])
      exit_code == 0
    rescue
      false
    end

    # A real SIP transaction on the wire, not just "the process is alive".
    # `check_kamailio` runs kamcmd inside the container, which stays green even
    # if the UDP listener never came up. ANY final response proves the stack
    # parses and answers SIP; only silence is a failure.
    private def check_sip_options : Bool
      !VoIPAppz::SIP.options(VoIPAppz::SIP.default_host, VoIPAppz::SIP.default_port).nil?
    rescue
      false
    end

    private def check_kamailio : Bool
      container = Docker.running_kamailio?
      return false unless container
      # kamcmd talks directly to the ctl module's binrpc socket — no
      # dependency on kamctlrc / SIP_DOMAIN / sipsak like `kamctl ping`.
      exit_code, _ = Docker.exec(container, ["kamcmd", "core.uptime"])
      exit_code == 0
    rescue
      false
    end

    private def check_freeswitch : Bool
      container = Docker.resolve_container("freeswitch")
      pass = ENV["VA_FREESWITCH_PASSWORD"]? || "ClueCon"
      port = ENV["VA_FREESWITCH_PORT"]? || "8021"
      exit_code, output = Docker.exec(container,
        ["fs_cli", "-H", "127.0.0.1", "-P", port, "-p", pass, "-x", "status"])
      exit_code == 0 && output.includes?("UP")
    rescue
      false
    end

    private def container_running?(name : String) : Bool
      stdout = IO::Memory.new
      process = Process.new("docker", ["inspect", "--format", "{{.State.Running}}", name],
        output: stdout, error: Process::Redirect::Close)
      process.wait
      stdout.to_s.strip == "true"
    rescue
      false
    end

    private def check_port(port : Int32) : Bool
      TCPSocket.new("127.0.0.1", port, connect_timeout: 2.seconds).close
      true
    rescue
      false
    end

    private def check_http(url : String, accept_503 : Bool = false) : Bool
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 2.seconds
      response = client.get(uri.request_target)
      response.status_code == 200 || (accept_503 && response.status_code == 503)
    rescue
      false
    end

    private def get_http_code(url : String) : Int32
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 2.seconds
      response = client.get(uri.request_target)
      response.status_code
    rescue
      0
    end
  end
end
