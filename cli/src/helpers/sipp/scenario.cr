require "yaml"
require "./media"

# A SIPp scenario compiler: YAML manifest in, SIPp XML scenario + RTP pcap out.
#
# Ported from sippy_cup (https://github.com/mojolingo/sippy_cup), MIT-licensed,
# Copyright (c) 2013 Mojo Lingo LLC. The step vocabulary and the SIP messages
# each step emits follow sippy_cup so its manifests run here unchanged; the two
# deliberate departures are marked DEVIATION below.
#
# Why this exists next to helpers/sip.cr: that client speaks whole SIP dialogs
# natively and is what health checks use, but it has no media and no call
# pacing. Everything that needs RTP, DTMF or a sustained call rate — IVR
# testing, load — needs SIPp, and SIPp needs an XML scenario nobody wants to
# hand-write.
module VoIPAppz::Sipp
  # YAML draws a hard line between 5 and 5.0, and every sippy_cup manifest in
  # the wild writes `calls_per_second: 5`. Take either.
  module Number
    def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Float64
      node.raise "expected a number" unless node.is_a?(YAML::Nodes::Scalar)
      node.value.to_f? || node.raise("expected a number, got `#{node.value}`")
    end

    def self.to_yaml(value : Float64, yaml : YAML::Nodes::Builder) : Nil
      yaml.scalar value
    end
  end

  # Everything a manifest can set. Keys match sippy_cup's manifest so its
  # examples are directly usable.
  class Options
    include YAML::Serializable

    # The manifest's own `name`, if it gave one. `name` below fills in a
    # fallback so the XML always carries something identifiable.
    @[YAML::Field(key: "name")]
    property given_name : String?
    property filename : String?

    # Where SIPp binds and who it talks to.
    property source : String?
    property source_port : Int32 = 8836
    property destination : String?
    # What to put in SIP/SDP when the bind address is not the reachable one
    # (NAT, a container bridge). Defaults to SIPp's own [local_ip].
    property advertise_address : String?
    property media_port : Int32?
    property transport_mode : String?

    # Who is calling whom.
    property from_user : String = "sipp"
    property to : String?
    property to_user : String?

    # Call volume.
    property max_concurrent : Int32?
    property concurrent_max : Int32?
    property number_of_calls : Int32?
    @[YAML::Field(converter: VoIPAppz::Sipp::Number)]
    property calls_per_second : Float64?
    @[YAML::Field(converter: VoIPAppz::Sipp::Number)]
    property calls_per_second_max : Float64?
    @[YAML::Field(converter: VoIPAppz::Sipp::Number)]
    property calls_per_second_incr : Float64?
    property calls_per_second_interval : Int32?

    # Reporting.
    property stats_file : String?
    property stats_interval : Int32?
    property summary_report_file : String?
    property errors_report_file : String?

    # Packetization to advertise in the SDP. Left out entirely when unset, which
    # is SIPp's own behaviour — set them where a peer requires them, as ED-137
    # trunks do (a=ptime:20, a=maxptime:30).
    property ptime : Int32?
    property maxptime : Int32?

    property dtmf_mode : String = "rfc2833"
    property scenario_variables : String?

    # Raw SIPp flags, passed through as given. A nil value is a bare flag.
    @[YAML::Field(key: "options")]
    property sipp_options : Hash(String, YAML::Any)?

    property steps : Array(String)?

    # An existing SIPp scenario to run verbatim, instead of `steps`.
    property scenario : String?
    property media : String?

    def self.from_manifest(yaml : String) : Options
      from_yaml yaml
    end

    def name : String
      @given_name || "My Scenario"
    end

    def to_target : String?
      @to || @to_user
    end

    # The user half of `to`, handed to SIPp as -s and substituted for [service].
    def to_service : String?
      to_target.try(&.split('@').first)
    end

    def to_domain : String
      target = to_target
      return "[remote_ip]" unless target
      # Assigned unconditionally: inside `target && (parts = …)` the compiler
      # still types parts as Array(String)? — the nil branch never assigns it.
      parts = target.split('@')
      parts.size > 1 ? parts[1] : "[remote_ip]"
    end

    def concurrency : Int32?
      @concurrent_max || @max_concurrent
    end

    # Down-snake-case the name the way sippy_cup does, so a manifest compiled
    # here lands on the same filenames it does there.
    def basename : String
      @filename || name.downcase.gsub(/\W+/, "_")
    end
  end

  # A minimal XML node. Hand-rolled rather than XML::Builder because SIPp
  # requires a newline on both sides of every CDATA block or it refuses to parse
  # the message, and because media nodes have to be resolved after the whole
  # scenario is known.
  class Element
    getter name : String
    getter attributes : Array({String, String})
    getter children : Array(Element)
    property body : String?
    # Set on media nodes when the scenario has no pcap to play: the node stays
    # in the tree but is left out of the output, so to_xml stays repeatable.
    property hidden : Bool = false

    def initialize(@name : String)
      @attributes = [] of {String, String}
      @children = [] of Element
    end

    def []=(key : String, value) : Nil
      text = value.to_s
      if index = @attributes.index { |(existing, _)| existing == key }
        @attributes[index] = {key, text}
      else
        @attributes << {key, text}
      end
    end

    def <<(child : Element) : Element
      @children << child
      child
    end

    def to_xml(io : IO, indent : String = "") : Nil
      return if @hidden
      io << indent << '<' << @name
      @attributes.each { |(key, value)| io << ' ' << key << "=\"" << escape(value) << '"' }

      if text = @body
        io << ">\n"
        io << "<![CDATA[" << text << "]]>\n"
        @children.each { |child| child.to_xml(io, indent + "  ") }
        io << indent << "</" << @name << ">\n"
      elsif @children.all?(&.hidden)
        io << "/>\n"
      else
        io << ">\n"
        @children.each { |child| child.to_xml(io, indent + "  ") }
        io << indent << "</" << @name << ">\n"
      end
    end

    private def escape(value : String) : String
      value.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;")
    end
  end

  class Scenario
    USER_AGENT      = "SIPp/voipappz"
    DEFAULT_RETRANS =                500
    MSEC            =              1_000
    DTMF_DURATION   =                250 # ms, matches Media::DTMF_DURATION

    getter options : Options
    getter errors : Array(String)
    getter media : Media?

    @to_addr : String? = nil
    # Assertions attach to the message that was just received, so the compiler
    # has to remember which one that was.
    @last_recv : Element? = nil
    # Timers attach to whichever message was last emitted — sent OR received —
    # because SIPp accepts start_rtd on both.
    @last_message : Element? = nil
    @checks = 0

    def initialize(@options : Options)
      @root = Element.new("scenario")
      @root["name"] = @options.name
      @media = nil
      @media_nodes = [] of Element
      @media_execs = [] of Element
      # Variables SIPp would otherwise warn about when a branch never assigns
      # them (a hangup we never initiate, say).
      @references = [] of String
      @message_variables = 0
      @errors = [] of String
      @advertise = @options.advertise_address || "[local_ip]"
      @from_user = @options.from_user
      @dtmf_mode = @options.dtmf_mode
      unless %w(rfc2833 info).includes?(@dtmf_mode)
        raise Error.new("dtmf_mode must be rfc2833 or info, got `#{@dtmf_mode}`")
      end
    end

    # `default_name` names the scenario when the manifest does not — callers
    # pass the manifest's own filename, the way sippy_cup does.
    def self.from_manifest(yaml : String, default_name : String? = nil) : Scenario
      options = Options.from_manifest(yaml)
      options.given_name ||= default_name
      scenario = new(options)
      steps = options.steps
      raise Error.new("manifest has no `steps`") unless steps
      scenario.build steps
      scenario
    end

    def valid? : Bool
      @errors.empty?
    end

    # Errors are collected rather than raised so one bad step reports its own
    # line number instead of hiding the rest of the manifest.
    def build(steps : Array(String)) : Nil
      steps.each_with_index do |step, index|
        begin
          apply step
        rescue e
          @errors << "step #{index + 1} (#{step}): #{e.message}"
        end
      end
    end

    private def apply(step : String) : Nil
      instruction, _, rest = step.strip.partition(' ')
      args = split_quoted rest

      case instruction
      when "invite"                    then invite
      when "register"                  then register argument(args, 0, "user"), args[1]?
      when "receive_invite",
           "wait_for_call"             then receive_invite
      when "send_trying", "send_100"   then send_trying
      when "send_ringing", "send_180"  then send_ringing
      when "send_answer"               then send_answer
      when "answer"                    then answer
      when "receive_ack"               then receive_ack
      when "receive_trying",
           "receive_100"               then handle_response 100
      when "receive_ringing",
           "receive_180"               then handle_response 180
      when "receive_progress",
           "receive_183"               then handle_response 183
      when "receive_answer"            then receive_answer
      when "receive_ok", "receive_200" then receive_ok
      when "wait_for_answer"           then wait_for_answer
      when "ack_answer"                then ack_answer
      when "sleep"                     then sleep_for argument(args, 0, "seconds")
      when "send_digits"               then send_digits argument(args, 0, "digits")
      when "receive_message"           then receive_message args[0]?
      when "start_timer"               then start_timer argument(args, 0, "number")
      when "stop_timer"                then stop_timer argument(args, 0, "number")
      when "assert_body"               then assert_body argument(args, 0, "regexp")
      when "refute_body"               then refute_body argument(args, 0, "regexp")
      when "assert_header"
        assert_header argument(args, 0, "header"), argument(args, 1, "regexp")
      when "refute_header"
        refute_header argument(args, 0, "header"), argument(args, 1, "regexp")
      when "send_bye"                  then send_bye
      when "receive_bye"               then receive_bye
      when "okay", "ack_bye"           then okay
      when "wait_for_hangup"           then wait_for_hangup
      when "hangup"                    then hangup
      when "call_length_repartition"
        partition_table "CallLengthRepartition", args
      when "response_time_repartition"
        partition_table "ResponseTimeRepartition", args
      else
        raise Error.new("unknown step `#{instruction}`")
      end
    end

    private def argument(args : Array(String), index : Int32, name : String) : String
      args[index]? || raise Error.new("missing argument `#{name}`")
    end

    # ---- Steps -------------------------------------------------------------

    def invite : Nil
      from_addr = "#{@from_user}@#{@advertise}:[local_port]"
      # The 101 payload id is fixed here and in Media — the two have to agree or
      # the far end will not recognise the DTMF events we replay.
      msg = <<-MSG
        INVITE sip:#{to_addr} SIP/2.0
        Via: SIP/2.0/[transport] #{@advertise}:[local_port];branch=[branch]
        From: "#{@from_user}" <sip:#{from_addr}>;tag=[call_number]
        To: <sip:#{to_addr}>
        Call-ID: [call_id]
        CSeq: [cseq] INVITE
        Contact: <sip:#{from_addr};transport=[transport]>
        Max-Forwards: 100
        User-Agent: #{USER_AGENT}
        Content-Type: application/sdp
        Content-Length: [len]

        v=0
        o=user1 53655765 2353687637 IN IP[local_ip_type] #{@advertise}
        s=-
        c=IN IP[media_ip_type] [media_ip]
        t=0 0
        m=audio [media_port] RTP/AVP 0 101
        a=rtpmap:0 PCMU/8000
        a=rtpmap:101 telephone-event/8000
        a=fmtp:101 0-15#{packetization}
        MSG

      node = send_message(msg, retrans: DEFAULT_RETRANS)
      action = node << Element.new("action")
      assign action, "remote_addr", to_addr
      assign action, "local_addr", from_addr
      assign action, "call_addr", to_addr
      reference "remote_addr", "local_addr", "call_addr"
    end

    def register(user : String, password : String? = nil) : Nil
      name, domain = parse_user user
      if password
        send_message register_message(domain, name), retrans: DEFAULT_RETRANS
        recv({"response" => "401", "auth" => "true", "optional" => "false"})
        send_message register_auth(domain, name, password), retrans: DEFAULT_RETRANS
        recv({"response" => "200", "optional" => "false"})
      else
        send_message register_message(domain, name), retrans: DEFAULT_RETRANS
      end
    end

    def receive_invite : Nil
      node = recv({"request" => "INVITE", "rrs" => "true"})
      action = node << Element.new("action")
      ereg action, "<sip:(.*)>.*;tag=([^;]*)", "From:", "dummy,remote_addr,remote_tag"
      ereg action, "<sip:(.*)>", "To:", "dummy,local_addr"
      assign action, "call_addr", "[$local_addr]"
      reference "dummy", "remote_addr", "remote_tag", "local_addr", "call_addr"
    end

    def send_trying : Nil
      send_message response_message(100, "Trying")
    end

    def send_ringing : Nil
      send_message response_message(180, "Ringing")
    end

    def send_answer : Nil
      msg = <<-MSG
        SIP/2.0 200 Ok
        [last_Via:]
        From: <sip:[$remote_addr]>;tag=[$remote_tag]
        To: <sip:[$local_addr]>;tag=[call_number]
        [last_Call-ID:]
        [last_CSeq:]
        Server: #{USER_AGENT}
        Contact: <sip:[$local_addr];transport=[transport]>
        Content-Type: application/sdp
        [routes]
        Content-Length: [len]

        v=0
        o=user1 53655765 2353687637 IN IP[local_ip_type] #{@advertise}
        s=-
        c=IN IP[media_ip_type] [media_ip]
        t=0 0
        m=audio [media_port] RTP/AVP 0
        a=rtpmap:0 PCMU/8000#{packetization}
        MSG

      start_media
      send_message msg, retrans: DEFAULT_RETRANS
    end

    def answer : Nil
      send_answer
      receive_ack
    end

    def receive_ack : Nil
      recv({"request" => "ACK"})
    end

    def receive_answer : Nil
      # rrs keeps the Route set available as [routes]; rtd records the response
      # time, which is what makes the repartition tables meaningful.
      node = recv({"response" => "200", "rrs" => "true", "rtd" => "true"})
      action = node << Element.new("action")
      ereg action, "<sip:(.*)>.*;tag=([^;]*)", "To:", "dummy,remote_addr,remote_tag"
      reference "dummy", "remote_addr", "remote_tag"
    end

    def receive_ok : Nil
      recv({"response" => "200"})
    end

    # DEVIATION from sippy_cup: its wait_for_answer also sends the ACK, while
    # its own README documents the step as the receives alone — so the manifest
    # in that same README (`wait_for_answer` followed by `ack_answer`) ACKs
    # twice and plays the media pcap twice on every call. The documented
    # behaviour is the one worth having.
    def wait_for_answer : Nil
      handle_response 100
      handle_response 180
      handle_response 183
      receive_answer
    end

    def ack_answer : Nil
      msg = <<-MSG
        ACK [next_url] SIP/2.0
        Via: SIP/2.0/[transport] #{@advertise}:[local_port];branch=[branch]
        From: "#{@from_user}" <sip:#{@from_user}@#{@advertise}:[local_port]>;tag=[call_number]
        To: <sip:#{to_addr}>[peer_tag_param]
        Call-ID: [call_id]
        CSeq: [cseq] ACK
        Contact: <sip:[$local_addr];transport=[transport]>
        Max-Forwards: 100
        User-Agent: #{USER_AGENT}
        Content-Length: 0
        [routes]
        MSG

      send_message msg
      start_media
    end

    def sleep_for(seconds : String) : Nil
      value = seconds.to_f? || raise Error.new("`sleep` needs a number of seconds, got `#{seconds}`")
      milliseconds = (value * MSEC).to_i
      pause milliseconds
      # The media has to be padded to match, or the pcap runs dry while the
      # scenario is still waiting.
      @media.try(&.silence(milliseconds))
    end

    def send_digits(digits : String) : Nil
      media = @media
      raise Error.new("`send_digits` needs media — put it after `ack_answer` or `answer`") unless media

      digits.each_char do |char|
        digit = char.to_s
        unless Media::DIGITS.includes?(digit)
          raise Error.new("invalid DTMF digit `#{digit}`")
        end

        case @dtmf_mode
        when "rfc2833"
          media.dtmf digit
          media.silence DTMF_DURATION
        when "info"
          send_message dtmf_info(digit)
          recv({"response" => "200"})
          pause DTMF_DURATION
        end
      end

      # One digit occupies its event plus the gap after it; the scenario has to
      # stand still for exactly as long as the media takes to play.
      pause(DTMF_DURATION * 2 * digits.size) if @dtmf_mode == "rfc2833"
    end

    def receive_message(regexp : String? = nil) : Nil
      node = recv({"request" => "MESSAGE"})
      if regexp
        action = node << Element.new("action")
        element = action << Element.new("ereg")
        element["regexp"] = regexp
        element["search_in"] = "body"
        element["check_it"] = "true"
        @message_variables += 1
        variable = "message_#{@message_variables}"
        element["assign_to"] = variable
        reference variable
      end
      okay
    end

    # Start response timer N on the message just emitted, and stop it on a later
    # one. SIPp reports each timer's distribution through the repartition
    # tables, which is where a p99 comes from.
    #
    # Two timers rather than one because the requirements measure two different
    # intervals — INVITE to ringing, and ringing to answer — and a single `rtd`
    # can only describe one of them. SIPp takes start_rtd on a recv as well as a
    # send, so the second timer can begin at a message we did not send.
    def start_timer(number : String) : Nil
      timer_attribute "start_rtd", number
    end

    def stop_timer(number : String) : Nil
      timer_attribute "rtd", number
    end

    private def timer_attribute(name : String, number : String) : Nil
      value = number.to_i? || raise Error.new("`#{name == "rtd" ? "stop" : "start"}_timer` takes a timer number, got `#{number}`")
      raise Error.new("timer numbers start at 1, got #{value}") unless value >= 1
      node = @last_message
      unless node
        raise Error.new("`#{name == "rtd" ? "stop" : "start"}_timer` has no message to time \u2014 put it after a send or receive step")
      end
      node[name] = value
    end

    # Fail the call unless the body of the message just received matches.
    #
    # This is how a scenario checks what the system under test PUT ON THE WIRE
    # rather than only that it answered: stand SIPp up as the far end, then
    # assert on the SDP it is offered. SIPp marks the call failed when the
    # regexp does not match, so the check lands in the exit code and the failure
    # counters instead of in someone's reading of a capture.
    def assert_body(regexp : String) : Nil
      check regexp, nil
    end

    # The same check against one header — `assert_header 'From:' 'sip:1234@'`.
    def assert_header(header : String, regexp : String) : Nil
      check regexp, header
    end

    # The inverse: fail the call when the match IS present.
    #
    # Half of a compliance rule is usually a prohibition — "omit the CN
    # payload", "offer only PCMA". Presence checks cannot express those: a
    # scenario that only asserts what SHOULD be there passes a message that
    # also carries what should not.
    def refute_body(regexp : String) : Nil
      check regexp, nil, inverse: true
    end

    def refute_header(header : String, regexp : String) : Nil
      check regexp, header, inverse: true
    end

    private def check(regexp : String, header : String?, inverse : Bool = false) : Nil
      node = @last_recv
      unless node
        verb = inverse ? "refute" : "assert"
        raise Error.new("`#{verb}_#{header ? "header" : "body"}` has nothing to check \u2014 put it after a receive step")
      end

      action = node.children.find { |child| child.name == "action" } || (node << Element.new("action"))
      element = action << Element.new("ereg")
      element["regexp"] = regexp
      element["search_in"] = header ? "hdr" : "body"
      element["header"] = header if header
      # check_it is the whole point: without it a non-match is silently ignored.
      if inverse
        element["check_it_inverse"] = "true"
      else
        element["check_it"] = "true"
      end
      @checks += 1
      variable = "check_#{@checks}"
      element["assign_to"] = variable
      reference variable
    end

    def send_bye : Nil
      msg = <<-MSG
        BYE sip:[$call_addr] SIP/2.0
        Via: SIP/2.0/[transport] #{@advertise}:[local_port];branch=[branch]
        From: <sip:[$local_addr]>;tag=[call_number]
        To: <sip:[$remote_addr]>;tag=[$remote_tag]
        Contact: <sip:[$local_addr];transport=[transport]>
        Call-ID: [call_id]
        CSeq: [cseq] BYE
        Max-Forwards: 100
        User-Agent: #{USER_AGENT}
        Content-Length: 0
        [routes]
        MSG

      send_message msg
    end

    def receive_bye : Nil
      recv({"request" => "BYE"})
    end

    def okay : Nil
      msg = <<-MSG
        SIP/2.0 200 OK
        [last_Via:]
        [last_From:]
        [last_To:]
        [last_Call-ID:]
        [last_CSeq:]
        Contact: <sip:[$local_addr];transport=[transport]>
        Max-Forwards: 100
        User-Agent: #{USER_AGENT}
        Content-Length: 0
        [routes]
        MSG

      send_message msg
    end

    def wait_for_hangup : Nil
      receive_bye
      okay
    end

    def hangup : Nil
      send_bye
      receive_ok
    end

    # ---- Output ------------------------------------------------------------

    # Resolves the media nodes against `pcap_path` and serializes. Repeatable:
    # nothing is deleted from the tree, so calling it twice gives the same XML.
    def to_xml(pcap_path : String? = nil) : String
      play = !!(pcap_path && !media_empty?)
      @media_nodes.each { |node| node.hidden = !play }
      @media_execs.each { |exec| exec["play_pcap_audio"] = pcap_path } if play

      reference_node = nil
      unless @references.empty?
        reference_node = Element.new("Reference")
        reference_node["variables"] = @references.join(",")
        @root << reference_node
      end

      xml = String.build do |io|
        io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
        io << %(<!DOCTYPE scenario SYSTEM "sipp.dtd">\n)
        @root.to_xml io
      end

      @root.children.delete(reference_node) if reference_node
      xml
    end

    # A scenario that opens by receiving is a server: SIPp listens rather than
    # calling out, and there is no destination to give it.
    def uas? : Bool
      @root.children.first?.try(&.name) == "recv"
    end

    def media_empty? : Bool
      media = @media
      media.nil? || media.empty?
    end

    # Writes the scenario and, when there is any, its media into `dir`.
    # Returns the two paths; the pcap is nil when the scenario plays nothing.
    def compile!(dir : String) : {String, String?}
      Dir.mkdir_p dir
      base = File.join(dir, @options.basename)
      pcap_path = nil

      unless media_empty?
        pcap_path = "#{base}.pcap"
        File.write pcap_path, @media.not_nil!.compile
      end

      scenario_path = "#{base}.xml"
      File.write scenario_path, to_xml(pcap_path)
      {scenario_path, pcap_path}
    end

    # ---- Building blocks ---------------------------------------------------

    # The trailing SDP attributes, or nothing at all. Built as a suffix rather
    # than as template lines so an unset ptime leaves no blank line behind.
    private def packetization : String
      String.build do |io|
        io << "\na=ptime:" << @options.ptime if @options.ptime
        io << "\na=maxptime:" << @options.maxptime if @options.maxptime
      end
    end

    private def to_addr : String
      @to_addr ||= "[service]@#{@options.to_domain}:[remote_port]"
    end

    private def parse_user(user : String) : {String, String}
      user = user[4..] if user.starts_with?("sip:")
      user = user.split(':').first
      name, _, domain = user.partition('@')
      domain = "[remote_ip]" if domain.empty?
      {name, domain}
    end

    # cars "cats and dogs" fish 'hammers' => ["cars", "cats and dogs", "fish", "hammers"]
    private def split_quoted(args : String) : Array(String)
      args.scan(/'.+?'|".+?"|[^ ]+/).map do |match|
        match[0].gsub(/^['"]|['"]$/, "")
      end
    end

    private def response_message(code : Int32, reason : String) : String
      <<-MSG
        SIP/2.0 #{code} #{reason}
        [last_Via:]
        From: <sip:[$remote_addr]>;tag=[$remote_tag]
        To: <sip:[$local_addr]>;tag=[call_number]
        [last_Call-ID:]
        [last_CSeq:]
        Server: #{USER_AGENT}
        Contact: <sip:[$local_addr];transport=[transport]>
        Content-Length: 0
        MSG
    end

    private def register_message(domain : String, user : String) : String
      <<-MSG
        REGISTER sip:#{domain} SIP/2.0
        Via: SIP/2.0/[transport] #{@advertise}:[local_port];branch=[branch]
        From: <sip:#{user}@#{domain}>;tag=[call_number]
        To: <sip:#{user}@#{domain}>
        Call-ID: [call_id]
        CSeq: [cseq] REGISTER
        Contact: <sip:#{@from_user}@#{@advertise}:[local_port];transport=[transport]>
        Max-Forwards: 10
        Expires: 120
        User-Agent: #{USER_AGENT}
        Content-Length: 0
        MSG
    end

    private def register_auth(domain : String, user : String, password : String) : String
      <<-MSG
        REGISTER sip:#{domain} SIP/2.0
        Via: SIP/2.0/[transport] #{@advertise}:[local_port];branch=[branch]
        From: <sip:#{user}@#{domain}>;tag=[call_number]
        To: <sip:#{user}@#{domain}>
        Call-ID: [call_id]
        CSeq: [cseq] REGISTER
        Contact: <sip:#{@from_user}@#{@advertise}:[local_port];transport=[transport]>
        Max-Forwards: 20
        Expires: 3600
        [authentication username=#{user} password=#{password}]
        User-Agent: #{USER_AGENT}
        Content-Length: 0
        MSG
    end

    private def dtmf_info(digit : String) : String
      <<-MSG
        INFO [next_url] SIP/2.0
        Via: SIP/2.0/[transport] #{@advertise}:[local_port];branch=[branch]
        From: "#{@from_user}" <sip:#{@from_user}@#{@advertise}:[local_port]>;tag=[call_number]
        To: <sip:#{to_addr}>[peer_tag_param]
        Call-ID: [call_id]
        CSeq: [cseq] INFO
        Contact: <sip:[$local_addr];transport=[transport]>
        Max-Forwards: 100
        User-Agent: #{USER_AGENT}
        [routes]
        Content-Length: [len]
        Content-Type: application/dtmf-relay

        Signal=#{digit}
        Duration=#{DTMF_DURATION}
        MSG
    end

    # DEVIATION from sippy_cup: it builds a fresh Media on every start_media,
    # silently discarding anything already recorded. Here the recording is kept
    # and only the play marker is added, so a scenario that starts media twice
    # still plays everything it asked for.
    private def start_media : Nil
      @media ||= Media.new
      node = Element.new("nop")
      action = node << Element.new("action")
      exec = action << Element.new("exec")
      @media_nodes << node
      @media_execs << exec
      @root << node
    end

    private def send_message(msg : String, retrans : Int32? = nil) : Element
      node = Element.new("send")
      node["retrans"] = retrans if retrans
      # A leading and trailing newline inside the CDATA is not cosmetic: SIPp
      # will not parse the message without them.
      node.body = "\n#{msg.strip}\n"
      @root << node
      @last_message = node
      node
    end

    private def recv(attributes : Hash(String, String)) : Element
      node = Element.new("recv")
      attributes.each { |key, value| node[key] = value }
      @root << node
      @last_recv = node
      @last_message = node
      node
    end

    private def handle_response(code : Int32) : Nil
      # Provisional responses are optional by default — a proxy that answers
      # without ringing first is not a failed call.
      recv({"response" => code.to_s, "optional" => "true"})
    end

    private def pause(milliseconds : Int32) : Nil
      node = Element.new("pause")
      node["milliseconds"] = milliseconds
      @root << node
    end

    private def partition_table(name : String, args : Array(String)) : Nil
      unless args.size == 3
        raise Error.new("#{name.underscore} needs min, max and interval")
      end
      min, max, interval = args.map do |value|
        value.to_i? || raise Error.new("#{name.underscore} takes integers, got `#{value}`")
      end
      raise Error.new("#{name.underscore} interval must be positive") unless interval > 0

      node = Element.new(name)
      node["value"] = (min..max).step(interval).to_a.join(",")
      @root << node
    end

    private def assign(action : Element, name : String, value : String) : Nil
      node = action << Element.new("assignstr")
      node["assign_to"] = name
      node["value"] = value
    end

    private def ereg(action : Element, regexp : String, header : String, assign_to : String) : Nil
      node = action << Element.new("ereg")
      node["regexp"] = regexp
      node["search_in"] = "hdr"
      node["header"] = header
      node["assign_to"] = assign_to
    end

    private def reference(*names : String) : Nil
      names.each { |name| @references << name unless @references.includes?(name) }
    end
  end
end
