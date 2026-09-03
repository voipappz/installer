require "http/client"
require "json"
require "./colors"
require "./env_file"
require "./project"

module VoIPAppz
  # GATUS IS THE SOURCE OF TRUTH for whether this node is healthy.
  #
  # It probes every service continuously, on its own schedule, from inside the
  # network — so "is this thing up" already has an answer one HTTP call away,
  # and re-implementing those probes in the CLI can only produce a SECOND
  # opinion that disagrees with the one the alerting acts on.
  #
  # This has been true, then not, then true again. `voipappz health` read this
  # API as its default until 2026-08-19, when the CLI left for va-crystal and
  # the code went with it ("single source of truth — gatus already probes every
  # service continuously; no point re-implementing probes"). The CLI came back
  # on 2026-08-31 without it, and scripts/check-gatus.sh had meanwhile
  # re-written the same read in POSIX sh + python3. Two implementations of one
  # question, in two languages, in one repo — and the surviving `--direct` flag
  # still described itself as skipping a Gatus the binary no longer knew about.
  # This is the shell one, ported back, and the shell one is gone.
  #
  # WHAT THE SHELL VERSION GOT RIGHT and the old Crystal did not, kept here:
  #   * gated groups — a red tile nobody gates on must not fail the verdict
  #   * waiting — a stack coming up is not a stack that is down
  #   * "never probed" is not "healthy"
  module Gatus
    extend self

    # A group named here MUST be green for this node to be called healthy.
    # Membership is the whole design: adding a probe to one of these groups
    # makes it load-bearing by default, rather than adding a tile nobody reads.
    #
    #   app     the data layer, the API, the gateway — the mothership itself
    #   sip     the ingress, this box's own SBC
    #   voip    the voip node via /health/node; on a split install, the far end
    #   metrics the Prometheus endpoints behind the dashboards
    #
    # There is no `alerts` group: two probes there queried InfluxDB for rows in
    # an `alerts` measurement nothing writes (voipappz-api persists threshold
    # breaches as Notification rows in postgres), so they were red on every node
    # that has ever run.
    DEFAULT_GATED = %w(app sip voip metrics)

    class Unreachable < Exception; end

    record Endpoint,
      group : String,
      name : String,
      up : Bool,
      detail : String do
      def gated?(gated : Array(String)) : Bool
        gated.includes?(group)
      end
    end

    def gated_groups : Array(String)
      if raw = ENV["VA_GATUS_GATED_GROUPS"]?.presence
        raw.split(/[\s,]+/).reject(&.empty?)
      else
        DEFAULT_GATED
      end
    end

    # The loopback publish. Gatus is on the docker network — compose reaches it
    # by service name — and publishes only on 127.0.0.1, for readers on the box.
    # No credential, because nothing is bound to a host interface and there is
    # therefore nothing exposed for one to protect.
    def port : String
      return ENV["VA_GATUS_PORT"].as(String) if ENV["VA_GATUS_PORT"]?.presence
      dotenv = begin
        VoIPAppz::EnvFile.load(File.join(VoIPAppz::Project.root, ".env"), first_wins: true)
      rescue
        {} of String => String
      end
      dotenv["VA_GATUS_PORT"]?.presence || "8080"
    end

    def url : String
      "http://127.0.0.1:#{port}/api/v1/endpoints/statuses"
    end

    def fetch : Array(Endpoint)
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 5.seconds
      response = client.get(uri.request_target)
      raise Unreachable.new("gatus answered HTTP #{response.status_code}") unless response.status_code == 200
      parse(response.body)
    rescue ex : Unreachable
      raise ex
    rescue ex
      raise Unreachable.new(ex.message.to_s)
    end

    # The newest result per endpoint, flattened. Kept apart from `fetch` so the
    # verdict logic can be tested against a recorded body instead of a server.
    def parse(body : String) : Array(Endpoint)
      doc = begin
        JSON.parse(body)
      rescue JSON::ParseException
        raise Unreachable.new("gatus answered something that is not JSON")
      end
      rows = doc.as_a? || raise Unreachable.new("gatus did not answer with a list of endpoints")

      rows.map do |ep|
        results = ep["results"]?.try(&.as_a?) || [] of JSON::Any
        latest = results.last?
        up = latest.try { |r| r["success"]?.try(&.as_bool?) } || false

        detail =
          if latest.nil?
            # NEVER PROBED IS NOT HEALTHY. An endpoint with no result yet has
            # never answered, which is a different thing from answering
            # correctly — and on a stack that just came up it is the normal
            # state for a few seconds, which is exactly why `wait` exists.
            "no result yet"
          elsif up
            ""
          else
            (latest["conditionResults"]?.try(&.as_a?) || [] of JSON::Any)
              .reject { |c| c["success"]?.try(&.as_bool?) }
              .map { |c| c["condition"]?.try(&.as_s?) || "?" }
              .join("; ")
          end

        Endpoint.new(
          group: ep["group"]?.try(&.as_s?) || "?",
          name: ep["name"]?.try(&.as_s?) || "?",
          up: up,
          detail: detail,
        )
      end
    end

    # The gated endpoints that are down. Empty means healthy.
    def failing(board : Array(Endpoint), gated : Array(String) = gated_groups) : Array(Endpoint)
      board.reject(&.up).select(&.gated?(gated))
    end

    # Poll until every gated endpoint is green, or the deadline passes. A stack
    # that is coming up is not a stack that is down — a single shot minutes
    # after `up` is a coin toss, and the old Crystal took it.
    def wait(timeout : Time::Span, interval : Time::Span = 5.seconds,
             gated : Array(String) = gated_groups, & : Array(Endpoint) -> Nil) : Array(Endpoint)
      deadline = Time.monotonic + timeout
      last = [] of Endpoint
      loop do
        begin
          last = fetch
          yield last
          return last if failing(last, gated).empty?
        rescue ex : Unreachable
          # Keep trying: gatus itself may still be starting. If it never
          # answers, the caller reports the LAST failure, not a silent pass.
          raise ex if Time.monotonic >= deadline
        end
        return last if Time.monotonic >= deadline
        sleep interval
      end
    end

    # `  ok  * app      postgres    ` — one line per probe, gated ones starred.
    def render(board : Array(Endpoint), gated : Array(String) = gated_groups) : String
      String.build do |io|
        board.each do |e|
          mark = e.up ? Colors.green("  ok  ") : Colors.red("  DOWN")
          io << mark << (e.gated?(gated) ? "* " : "  ")
          io << e.group.ljust(9) << e.name.ljust(32)
          io << Colors.dim(e.detail) unless e.detail.empty?
          io << '\n'
        end
        io << Colors.dim("  (* = gated: must be green for this node to be called healthy)")
      end
    end
  end
end
