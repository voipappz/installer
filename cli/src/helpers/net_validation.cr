module VoIPAppz
  # Pure IPv4 / CIDR validation used by `voipappz sbc egress address`. Deterministic,
  # dependency-free (no I/O) so it's unit-testable — see cli/spec/net_validation_spec.cr.
  module NetValidation
    extend self

    # Validate a dotted-quad IPv4: exactly four octets, each 0-255, canonical
    # (no leading zeros, no garbage like "1.2.3.4.5" or "10.0x1.0.1").
    def valid_ipv4?(s : String) : Bool
      octets = s.split(".")
      return false unless octets.size == 4
      octets.all? do |o|
        v = o.to_i?
        !v.nil? && v >= 0 && v <= 255 && o == v.to_s
      end
    end

    # A node must advertise and bind a real interface address. Loopback and
    # unspecified addresses can make every local health check pass while no
    # phone or carrier can reach the SIP plane.
    def usable_node_ipv4?(s : String) : Bool
      return false unless valid_ipv4?(s)
      first = s.split('.', 2).first.to_i
      first != 0 && first != 127
    end

    # Mothership responses can rewrite the running SIP plane, and registration
    # carries a root credential. Both paths therefore share one transport
    # policy: TLS everywhere except a literal loopback used by local tests.
    def safe_mothership_transport?(scheme : String?, host : String?) : Bool
      return false unless host
      scheme == "https" || (scheme == "http" && loopback_host?(host))
    end

    def loopback_host?(host : String) : Bool
      host == "localhost" || host == "::1" ||
        (valid_ipv4?(host) && host.split('.').first == "127")
    end

    # Parse "ip" or CIDR "ip/mask" into {ip, mask}. A `/mask` in the input wins
    # over default_mask. Returns nil (caller rejects) on a bad IPv4 or a mask
    # outside 0-32 — so `address add --ip 192.168.0.0/16` just works.
    def parse_cidr(input : String, default_mask : Int32) : {String, Int32}?
      ip_part, slash, mask_part = input.partition("/")
      mask = slash.empty? ? default_mask : mask_part.to_i?
      return nil if mask.nil? || mask < 0 || mask > 32
      return nil unless valid_ipv4?(ip_part)
      {ip_part, mask}
    end

    # --- setup-wizard input validation --------------------------------------
    # Pure predicates so the wizard can reject bad answers at the prompt
    # instead of writing them into .env and failing hours later at runtime.

    # A TCP/UDP port: 1-65535, canonical decimal (rejects "0", "587 ", "05").
    def valid_port?(s : String) : Bool
      v = s.to_i?
      !v.nil? && v >= 1 && v <= 65535 && s == v.to_s
    end

    # The SMTP submission ports we can actually reason about. 25 is plain
    # relay (usually blocked outbound by cloud providers), 587 STARTTLS
    # submission, 465 implicit TLS, 2525 the common alternate. Anything else
    # is accepted but worth a warning — it's more often a typo than intent.
    def common_smtp_port?(s : String) : Bool
      {"25", "465", "587", "2525"}.includes?(s)
    end

    # Deliberately permissive: one @, non-empty local part, a dotted domain
    # with a 2+ char TLD, no whitespace. Enough to catch typos ("admin@",
    # "admin at x.com") without rejecting valid-but-unusual addresses.
    def valid_email?(s : String) : Bool
      return false if s.empty? || s.includes?(" ")
      local, at, domain = s.partition("@")
      return false if at.empty? || local.empty?
      valid_hostname?(domain) && domain.includes?(".")
    end

    # A DNS hostname: dot-separated labels of [A-Za-z0-9-], no leading/trailing
    # hyphen per label, each label 1-63 chars, total <= 253. Accepts a bare
    # single label ("localhost", "smtp") — callers requiring a FQDN check for
    # a "." themselves.
    def valid_hostname?(s : String) : Bool
      return false if s.empty? || s.size > 253 || s.starts_with?(".") || s.ends_with?(".")
      s.split(".").all? do |label|
        next false if label.empty? || label.size > 63
        next false if label.starts_with?("-") || label.ends_with?("-")
        label.each_char.all? { |c| c.ascii_alphanumeric? || c == '-' }
      end
    end

    # An https:// URL with a real host — used for webhook inputs, where a
    # plain-http or truncated paste silently breaks alerting.
    # ── Interface addresses, parsed ────────────────────────────────────────
    #
    # Two shapes because there are two sources. `ip -4 -o addr show` is the
    # good one: it names the interface, so docker bridges can be dropped.
    # `hostname -I` is the fallback for a host with no iproute2 — act's runner
    # image (catthehacker/ubuntu) ships none, and neither does a minimal
    # Debian, and there setup used to exit 1 with "No non-loopback IPv4
    # address detected" on a box that plainly had an address.
    #
    # Parsers, not detection: no I/O here, so both shapes are unit-testable
    # (cli/spec/net_validation_spec.cr). setup.cr does the running.

    # "2: eth0  inet 10.0.0.5/24 brd ... scope global eth0"
    def interface_ips_from_ip_output(text : String) : Array(NamedTuple(iface: String, ip: String))
      out = [] of NamedTuple(iface: String, ip: String)
      text.strip.split("\n").each do |line|
        parts = line.split
        next if parts.size < 4
        iface = parts[1].rstrip(':')
        next unless bindable_iface?(iface)
        ip = parts[3].split("/").first
        next unless usable_node_ipv4?(ip)
        out << {iface: iface, ip: ip}
      end
      out
    end

    # "10.0.0.5 172.17.0.1 fe80::1" — addresses only, in an order that has
    # been seen to put a stale lease first, so the interface name is lost and
    # with it the chance to drop a docker bridge. Good enough as a fallback:
    # it only runs where `ip` is absent, which in practice is inside a
    # container whose one address IS its eth0.
    def interface_ips_from_hostname_output(text : String) : Array(NamedTuple(iface: String, ip: String))
      text.split.compact_map do |field|
        next unless usable_node_ipv4?(field)
        next if field.starts_with?("169.254.")   # link-local: no route anywhere
        {iface: "host", ip: field}
      end
    end

    # docker0, br-*, veth* are never a bind target for SIP or HTTP, and lo
    # would make every local health check pass while no phone could reach it.
    def bindable_iface?(iface : String) : Bool
      return false if iface == "lo" || iface == "docker0"
      return false if iface.starts_with?("br-") || iface.starts_with?("veth")
      true
    end

    def valid_https_url?(s : String) : Bool
      return false unless s.starts_with?("https://")
      rest = s[8..]
      host = rest.split('/')[0].split('?')[0].split('#')[0]
      return false if host.empty?
      # Strip an optional :port before validating the host itself.
      host, _, port = host.partition(":")
      return false unless port.empty? || valid_port?(port)
      valid_hostname?(host)
    end
  end
end
