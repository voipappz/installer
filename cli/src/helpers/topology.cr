require "./deploy_config"

module VoIPAppz
  # Topology classification + per-leg IP derivation for the granular
  # `ip_address_<role>_<int|ext>_<sip|rtp>` schema.
  #
  # Pure functions — `local_ips` is passed in (not read from the host) so the
  # logic is fully unit-testable and deterministic.
  module Topology
    extend self

    # The eight granular per-leg field names, in canonical write order.
    LEG_FIELDS = [
      "ip_address_internal_int_sip",
      "ip_address_internal_ext_sip",
      "ip_address_internal_int_rtp",
      "ip_address_internal_ext_rtp",
      "ip_address_external_int_sip",
      "ip_address_external_ext_sip",
      "ip_address_external_int_rtp",
      "ip_address_external_ext_rtp",
    ]

    # Classify the host's network topology relative to its public IP:
    #   :flat        — single IP for everything (internal == external)
    #   :public_nic  — public IP is bound to a real NIC on this host
    #   :nat         — public IP lives on an upstream NAT (not on any NIC)
    def detect(internal_ip : String, external_ip : String, local_ips : Set(String)) : Symbol
      return :flat if internal_ip == external_ip
      local_ips.includes?(external_ip) ? :public_nic : :nat
    end

    # Compute the eight granular per-leg fields for a given topology.
    #
    # Key convention — MUST match the consumer (node sofia.cr / sofia.ecr):
    #   ip_address_<profile>_<role>_<media>
    #     <profile> internal = LAN-phone sofia profile · external = carrier profile
    #     <role>    int = local BIND addr · ext = ADVERTISED addr (Contact/Via/SDP)
    #     <media>   sip · rtp
    # The external profile's RTP must BIND the public NIC on :public_nic, or the
    # carrier's media (sent to the advertised public IP) never reaches FS → one-way
    # / silent audio. Its SIP always binds LAN because the co-located kamailio SBC
    # relays carrier signalling to FS over the LAN.
    def derive_leg_ips(internal_ip : String, external_ip : String, topology : Symbol) : Hash(String, String)
      lan = internal_ip
      pub = external_ip
      ext_rtp_bind = topology == :public_nic ? pub : lan

      {
        # internal sofia profile (LAN phones): bind + advertise the LAN IP
        "ip_address_internal_int_sip" => lan, # SIP bind
        "ip_address_internal_ext_sip" => lan, # SIP advertised
        "ip_address_internal_int_rtp" => lan, # RTP bind
        "ip_address_internal_ext_rtp" => lan, # RTP advertised
        # external sofia profile (carriers): SIP binds LAN (kamailio relay) &
        # advertises public; RTP binds the public NIC (:public_nic) & advertises public
        "ip_address_external_int_sip" => lan,          # SIP bind (kamailio relays here)
        "ip_address_external_ext_sip" => pub,          # SIP advertised
        "ip_address_external_int_rtp" => ext_rtp_bind, # RTP bind (public on :public_nic)
        "ip_address_external_ext_rtp" => pub,          # RTP advertised
      }
    end

    # Apply the granular schema to every sip_interface in the config. Existing
    # operator overrides are preserved — only missing/empty keys are written —
    # so a hand-tuned va.yaml survives a re-run of setup. Returns the topology
    # so callers can report it.
    def populate!(config : DeployConfig, internal_ip : String, external_ip : String, local_ips : Set(String)) : Symbol
      topology = detect(internal_ip, external_ip, local_ips)
      derived = derive_leg_ips(internal_ip, external_ip, topology)
      config.sip_interfaces.each do |si|
        derived.each do |key, value|
          existing = si.profile[key]?
          si.profile[key] = value if existing.nil? || existing.empty?
        end
      end
      topology
    end

    def label(topology : Symbol) : String
      case topology
      when :flat       then "flat (single IP everywhere)"
      when :nat        then "NAT'd (LAN bind, public advertised)"
      when :public_nic then "public IP on NIC (direct bind)"
      else                  topology.to_s
      end
    end
  end
end
