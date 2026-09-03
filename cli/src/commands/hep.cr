require "admiral"
require "json"
require "../helpers/colors"
require "../helpers/node_capture"
require "../helpers/nats_control"
require "./sbc"

module VoIPAppz::Commands
  # `voipappz sbc hep` — SIP capture on THIS node, from inside the image.
  #
  # Live debug and long-term never mix here:
  #   tail     the live subject over the broker, session-gated, nothing stored
  #   query    InfluxDB, the long-term store, a different question
  #   status / enable / disable   both halves — kamailio's mirror, the node's collector
  #
  # The development CLI's `trace hep` (config patching, its own collector) is
  # not this: the node IS the collector, and the config is baked.
  class SbcHep < Admiral::Command
    define_help description: "SIP capture on this node: status, enable/disable, tail, query"

    register_sub_command status, type: Status
    register_sub_command enable, type: Enable
    register_sub_command disable, type: Disable
    register_sub_command tail, type: Tail
    register_sub_command query, type: VoIPAppz::Commands::Kamailio::HepGroup::Query

    def run
      puts help
    end

    # What both `status` and the health row print from.
    def self.describe(state : JSON::Any) : Array(String)
      lines = [] of String
      bound = state["bound"]?.try(&.as_bool?) || false
      trace = state["kamailio_trace_on"]?
      trace_s = trace.nil? || trace.raw.nil? ? Colors.yellow("unknown") : (trace.as_bool ? Colors.green("on") : Colors.yellow("off"))
      lines << "  collector    #{bound ? Colors.green("bound") : Colors.red("NOT bound")} udp/#{state["listen"]?.try(&.as_s?) || "?"}"
      lines << "  kamailio     trace #{trace_s}"
      lines << "  node gate    #{(state["enabled"]?.try(&.as_bool?) || false) ? Colors.green("open") : Colors.yellow("paused")}"
      ago = state["last_packet_ago"]?
      lines << "  last packet  #{ago.nil? || ago.raw.nil? ? Colors.dim("none yet") : "#{ago.as_i64}s ago"}"
      lines << "  live stream  #{state["stream"]?.try(&.as_s?)}  #{(state["streaming"]?.try(&.as_bool?) || false) ? Colors.green("open (#{state["stream_seconds_left"]?}s left)") : Colors.dim("closed — nothing published")}"
      lines << "  influx       #{state["influx"]?.try(&.as_s?)}"
      rx = state["hep_packets_received_total"]?.try(&.as_i64?) || 0
      wr = state["hep_sip_written_total"]?.try(&.as_i64?) || 0
      pe = state["hep_parse_errors_total"]?.try(&.as_i64?) || 0
      we = state["hep_influx_write_errors_total"]?.try(&.as_i64?) || 0
      pub = state["hep_published_total"]?.try(&.as_i64?) || 0
      lines << "  counters     rx #{rx} · written #{wr} · published #{pub} · parse errs #{pe} · write errs #{we}"
      lines
    end

    class Status < Admiral::Command
      define_help description: "Kamailio mirror + node collector state, with counters"
      define_flag json : Bool, description: "Emit the node's /capture document", default: false

      def run
        state = VoIPAppz::NodeCapture.state
        unless state
          STDERR.puts Colors.error("the node is not answering at #{VoIPAppz::NodeCapture.url}")
          exit 1
        end
        if flags.json
          puts state.to_json
          return
        end
        puts Colors.header("SIP capture")
        SbcHep.describe(state).each { |l| puts l }
      end
    end

    class Enable < Admiral::Command
      define_help description: "Start capturing (kamailio mirrors, node writes to InfluxDB)"

      def run
        reply = VoIPAppz::NodeCapture.control("enable")
        SbcHep.report(reply, "capture enabled")
      end
    end

    class Disable < Admiral::Command
      define_help description: "Stop capturing (kamailio stops mirroring, node stops writing)"

      def run
        reply = VoIPAppz::NodeCapture.control("disable")
        SbcHep.report(reply, "capture disabled")
      end
    end

    def self.report(reply : JSON::Any?, done : String)
      unless reply
        STDERR.puts Colors.error("the node is not answering at #{VoIPAppz::NodeCapture.url}")
        exit 1
      end
      unless reply["status"]? == "success"
        STDERR.puts Colors.error(reply["message"]?.try(&.as_s?) || reply.to_json)
        exit 1
      end
      puts Colors.success("#{Colors::CHECK} #{done}")
      if capture = reply["capture"]?
        describe(capture).each { |l| puts l }
      end
    end

    class Tail < Admiral::Command
      define_help description: "Live SIP as it crosses this node, sngrep-style (nothing stored)"
      define_flag call : String, description: "Only this Call-ID (substring)", default: ""
      define_flag method : String, description: "Only these transaction methods, e.g. INVITE,REGISTER", default: ""
      define_flag raw : Bool, description: "Print the full SIP message under each line", default: false
      define_flag lines : Int32, description: "Stop after this many matching messages (0 = until Ctrl-C)", default: 0
      define_flag timeout : Int32, description: "Stop after this many seconds (0 = never)", default: 0
      define_flag url : String, description: "NATS URL (overrides VA_NATS_URL / NATS_URL)", default: ""
      define_flag node_uuid : String, description: "Node UUID (overrides VA_NODE_UUID / NODE_UUID)", default: ""
      define_flag json : Bool, description: "Print the node's JSON documents instead of lines", default: false

      def run
        url = VoIPAppz::NodeCapture.broker_url(flags.url)
        uuid = VoIPAppz::NodeCapture.node_uuid(flags.node_uuid)
        methods = flags.method.split(',').map(&.strip.upcase).reject(&.empty?)

        session = VoIPAppz::NodeCapture::Session.new(url, uuid)
        Signal::INT.trap { session.stop }
        Signal::TERM.trap { session.stop }

        unless flags.json
          STDERR.puts Colors.dim("live SIP on #{VoIPAppz::NodeCapture.stream_subject(uuid)} — Ctrl-C to stop")
        end
        shown = 0
        timeout = flags.timeout > 0 ? flags.timeout.seconds : nil
        begin
          session.each(timeout) do |line|
            next true unless line.matches?(methods, flags.call)
            if flags.json
              puts line.to_json
            else
              puts line.format
              if flags.raw
                line.raw.each_line { |l| puts "    #{Colors.dim(l.chomp)}" }
                puts ""
              end
            end
            STDOUT.flush
            shown += 1
            flags.lines == 0 || shown < flags.lines
          end
        rescue ex
          STDERR.puts Colors.error(ex.message.to_s)
          exit 1
        ensure
          session.close
        end
        # A tail that asked for N lines and got none is a failed assertion,
        # which is what the switch proof relies on.
        exit 2 if flags.lines > 0 && shown == 0
      end
    end
  end
end
