require "./deploy_config"
require "./project"

module VoIPAppz
  # Renders `config/kamailio/ingress/dispatcher.list` from `config/va.yaml`.
  #
  # The ingress has NO DATABASE. Its whole state is "which destinations exist",
  # which is a list, so it reads the dispatcher's native plain-text format
  # instead of carrying SQLite, a kamdbctl bootstrap and a data volume for three
  # rows. (The EGRESS keeps SQLite — usrloc, dialog, domain and permissions are
  # real state a file cannot hold, and it also takes calls directly from
  # providers, so its own carrier logic stays exactly where it is.)
  #
  # va.yaml is the source of truth and this file is DERIVED: `voipappz setup`
  # writes it at init and `voipappz sbc ingress sync` rewrites it and reloads. Editing
  # the file by hand works until the next sync overwrites it.
  #
  # The generated file is still tracked in git, because compose bind-mounts it:
  # a missing bind-mount source makes docker create an empty DIRECTORY and mount
  # it over the path, and kamailio then fails to read its destinations.
  module DispatcherList
    extend self

    # Host path (bind-mount source) and the path inside the container.
    # RELATIVE to the project root — use `host_path` to get the real location.
    # As a bare relative string this reported "missing" on a node, where the
    # binary is in /opt/cli/bin and the project in /opt/va.
    HOST_PATH      = "config/kamailio/ingress/dispatcher.list"
    CONTAINER_PATH = "/etc/kamailio/dispatcher.list"

    # Absolute path to the generated file on this machine.
    def host_path : String
      VoIPAppz::Project.path(HOST_PATH)
    end

    SET_INGRESS = 1   # FreeSWITCH internal — the default destination
    SET_EGRESS  = 2   # FreeSWITCH external — carrier-sourced traffic

    # Carrier SOURCE addresses. Not a routing target: membership is how the lua
    # recognises a carrier (`ds_is_from_list`), replacing the permissions
    # `address` table. Recognising a source and listing a destination are the
    # same shape of fact, so one file and one module cover both.
    SET_CARRIERS = 100

    # DS_DISABLED_DST. Set 100 entries are identified, never dialled, so this
    # keeps the keepalive prober from OPTIONS-pinging a carrier. Verified
    # against kamailio 5.6.2: flags=4 prints as "DX" in `kamcmd dispatcher.list`
    # and is still matched by ds_is_from_list, which compares the source address
    # and ignores state. (flags=2 is DS_TRYING_DST — not what you want.)
    FLAG_DISABLED = 4

    MANAGED_PREFIX = "managed:yaml/"

    record Entry, setid : Int32, destination : String, flags : Int32,
      attrs : String, description : String

    # Destinations + carrier sources, in the order they are written.
    def entries(config : VoIPAppz::DeployConfig) : Array(Entry)
      out = [] of Entry

      fs_nodes = config.nodes.select { |n| n.roles.includes?("switch") }
      fs_nodes.each do |n|
        legacy_internal = n.profile["ip_address_internal"]?
        legacy_external = n.profile["ip_address_external"]? || legacy_internal
        next if legacy_internal.nil? || legacy_internal.empty?

        config.sip_interfaces.each do |si|
          next if !si.node_uuid.empty? && si.node_uuid != n.uuid
          port_internal = si.profile["port_internal"]? || "5060"
          port_external = si.profile["port_external"]? || "5090"

          int_sip_bind = pick(si, n, "ip_address_internal_int_sip", legacy_internal)
          ext_sip_bind = pick(si, n, "ip_address_internal_ext_sip", legacy_internal)
          # attrs is what the EGRESS turns into the advertised RTP address; the
          # ingress never reads it. Carried anyway so the two stay comparable.
          ingress_attrs = pick(si, n, "ip_address_external_int_rtp", legacy_internal || "")
          egress_attrs = pick(si, n, "ip_address_external_ext_rtp", legacy_external || "")

          out << Entry.new(SET_INGRESS, "sip:#{int_sip_bind}:#{port_internal}", 0,
            ingress_attrs, "#{MANAGED_PREFIX}#{si.name}/INGRESS")
          out << Entry.new(SET_EGRESS, "sip:#{ext_sip_bind}:#{port_external}", 0,
            egress_attrs, "#{MANAGED_PREFIX}#{si.name}/EGRESS")
        end
      end

      # Carrier sources — the same va.yaml gateways that seed the egress's
      # permissions `address` table, expressed as set 100 here.
      config.sip_interfaces.each do |si|
        default_tag = "#{MANAGED_PREFIX}#{si.name}/gw"
        si.gateways.each do |gw|
          next if gw.ip.empty?
          tag = gw.tag.empty? ? default_tag : gw.tag
          # No mask: the dispatcher matches a source ADDRESS, not a CIDR range.
          # A carrier given as a /24 in va.yaml is listed by its base address —
          # see the note in the rendered header.
          out << Entry.new(SET_CARRIERS, "sip:#{gw.ip}:0", FLAG_DISABLED, "", tag)
        end
      end

      out
    end

    def render(config : VoIPAppz::DeployConfig) : String
      render(entries(config))
    end

    # Overload taking rows already computed: `sync` and `setup` both want the
    # list AND the file, and calling render(config) after entries(config) walked
    # nodes x sip_interfaces x gateways twice for one result.
    def render(rows : Array(Entry)) : String

      String.build do |io|
        io << <<-HEADER
        # kamailio-ingress destinations — GENERATED from config/va.yaml.
        #
        # Rewritten by `voipappz setup` and `voipappz sbc ingress sync`; hand edits are
        # lost on the next sync. Change config/va.yaml instead.
        #
        # The ingress is a forwarder: it picks a set and relays. That needs a
        # list of destinations and nothing else, so it reads this file rather
        # than carrying a SQLite database, a kamdbctl bootstrap and a data
        # volume. The EGRESS keeps SQLite — usrloc, dialog, domain and
        # permissions are real state a file cannot hold.
        #
        # Reload without a restart:  kamcmd dispatcher.reload
        #
        # Format: setid destination flags priority attrs description
        #
        #   set #{SET_INGRESS}   FreeSWITCH internal — the default for everything
        #   set #{SET_EGRESS}   FreeSWITCH external — carrier-sourced traffic
        #   set #{SET_CARRIERS} CARRIER SOURCES. Not a routing target: membership is how the
        #           ingress recognises a carrier (ds_is_from_list), which is what the
        #           permissions `address` table used to do. Written with flags=#{FLAG_DISABLED}
        #           (DS_DISABLED_DST) so the keepalive prober never pings a carrier;
        #           a disabled entry is still matched by ds_is_from_list, which
        #           compares the source address and ignores state. Port 0 = any
        #           source port, which is what carriers use.
        #
        #           A carrier given as a CIDR range in va.yaml is listed by its base
        #           address only — the dispatcher matches an address, not a range.
        #           Ranged carriers still work through the EGRESS, whose permissions
        #           `address` table does match CIDR and which takes provider calls
        #           directly.

        HEADER
        io << "\n"

        if rows.empty?
          io << <<-EMPTY
          # NOTHING CONFIGURED YET. An empty list is FAIL-CLOSED: the ingress
          # answers 404 to every call rather than black-holing it, so an unseeded
          # node is loud instead of looking like a routing bug.
          #
          # Populate config/va.yaml (nodes with role=switch, sip_interfaces, and
          # sip_interfaces[].gateways for carriers), then: voipappz sbc ingress sync
          EMPTY
          io << "\n"
        else
          rows.each do |e|
            io << e.setid << " " << e.destination << " " << e.flags << " 0 "
            io << "\"" << e.attrs << "\" \"" << e.description << "\"\n"
          end
        end
      end
    end

    # Write the file, creating parent directories. Returns the path written.
    def write(config : VoIPAppz::DeployConfig, root : String = VoIPAppz::Project.root) : String
      write(entries(config), root)
    end

    def write(rows : Array(Entry), root : String = VoIPAppz::Project.root) : String
      path = File.join(root, HOST_PATH)
      Dir.mkdir_p(File.dirname(path))
      File.write(path, render(rows))
      path
    end

    # Resolve an IP-ish profile key from sip_interface first, then node, then
    # the default — the same precedence `sbc egress sync` uses, so the
    # two backends never disagree about where FreeSWITCH is.
    def pick(si, n, key : String, default : String) : String
      v = si.profile[key]?
      return v if v && !v.empty?
      v = n.profile[key]?
      return v if v && !v.empty?
      default
    end

    # What kamailio reports for a destination, decoded.
    #
    # `kamcmd dispatcher.list` prints a two-letter FLAGS field and nothing that
    # says what it means. Operators read "D" as "something is broken", and for
    # set 100 that is exactly backwards: carrier SOURCES are identification
    # only, never dialled, so disabled is the CORRECT state for them. Meanwhile
    # a routing target quietly going Inactive because FreeSWITCH stopped
    # answering keepalives is a real outage — and in raw output the two look
    # equally alarming.
    #
    #   first letter   A active   I inactive   T trying
    #   second letter  X not probed   P probing   D disabled
    record Target,
      setid : Int32,
      uri : String,
      flags : String do
      def disabled? : Bool
        flags.includes?("D")
      end

      def inactive? : Bool
        flags.starts_with?("I")
      end

      # Set 100 is not a routing target — membership identifies a carrier.
      def source_only? : Bool
        setid == SET_CARRIERS
      end

      # Can this destination actually take a call right now?
      def usable? : Bool
        return true if source_only?
        !disabled? && !inactive?
      end

      def state : String
        return "source" if source_only?
        return "disabled" if disabled?
        return "DOWN" if inactive?
        flags.starts_with?("T") ? "trying" : "up"
      end

      def note : String
        if source_only?
          "carrier source — identified, never dialled"
        elsif disabled?
          "administratively disabled"
        elsif inactive?
          "not answering OPTIONS keepalives"
        else
          ""
        end
      end
    end

    # CAN A CALL ROUTE RIGHT NOW — one answer, for every command that shows the
    # dispatcher.
    #
    # KAMAILIO IS THE ONE THAT CHECKS. It pings each destination with OPTIONS
    # and drops it after three misses, so the flags are a live verdict about a
    # real port, not a config assertion. Nothing else in the stack knows it:
    # gatus probes `tcp://dockerhost:5060`, which succeeds because kamailio IS
    # listening, so monitoring stays green while every call 404s.
    #
    # Set 100 is excluded: a carrier SOURCE is identified, never dialled, and
    # disabled is its correct state.
    enum Routing
      Ok       # at least one target can take a call
      Degraded # some down, some up
      Down     # nothing can take a call — every call 404s
    end

    def routing(targets : Array(Target)) : Routing
      routable = targets.reject(&.source_only?)
      return Routing::Down if routable.empty?
      down = routable.reject(&.usable?)
      return Routing::Down if down.size == routable.size
      down.empty? ? Routing::Ok : Routing::Degraded
    end

    # The exit code `status` uses for the same meaning, so a script switching on
    # it does not have to know which command answered.
    EXIT_DOWN = 3

    # Parse `kamcmd dispatcher.list`. The format is kamailio's own nested block
    # text, not JSON — so this reads the three fields that matter and ignores
    # the rest rather than pretending to parse the whole structure.
    def parse_kamcmd(output : String) : Array(Target)
      targets = [] of Target
      setid = 0
      uri = ""
      output.each_line do |line|
        line = line.strip
        if m = line.match(/\AID:\s*(\d+)\z/)
          setid = m[1].to_i
        elsif m = line.match(/\AURI:\s*(\S+)\z/)
          uri = m[1]
        elsif m = line.match(/\AFLAGS:\s*(\S+)\z/)
          targets << Target.new(setid, uri, m[1]) unless uri.empty?
          uri = ""
        end
      end
      targets
    end
  end
end
