require "./deploy_config"
require "./env_file"
require "./node_env"

module VoIPAppz
  # THE NODE THIS HOST HAS INSTALLED, resolved from its own files.
  #
  # `install.sh` leaves exactly two things behind that describe a node:
  # `<INSTALL_DIR>/config/va.yaml` (bind-mounted into the container at
  # /tmp/node.yaml) and `<INSTALL_DIR>/.env` (the secrets and service flags the
  # image cannot derive from that YAML). There is no docker-compose.yaml and no
  # config/services.tsv, and there never will be: a node is one `docker run`,
  # and the installer deletes a stale compose file if it finds one.
  #
  # Everything else in this CLI resolves through the MOTHERSHIP's compose
  # project (Project.root, Services). On a node host that project is absent, so
  # the commands that exist to manage a running node —
  #
  #     voipappz sbc egress status
  #
  # — died with `Unhandled exception: no service catalog at ./config/services.tsv`
  # over fourteen `???` frames, on the box the command is FOR. This module is
  # the other source: the local environment files, which a node always has.
  module NodeLocal
    extend self

    # install.sh's INSTALL_DIR and its default. `voipappz node install` honours
    # the same variable, so both halves point at one directory.
    DEFAULT_INSTALL_DIR = "/opt/voipappz"

    # THE CONTAINER NAME IS install.sh's, not a guess: it passes
    # `--name va-voip` and states that it owns the name ("replacing it IS how a
    # node is upgraded"). VA_VOIP_CONTAINER still overrides it through
    # Docker.container_override, which is how a second stack on one box is
    # driven.
    CONTAINER = "va-voip"

    VA_YAML  = "config/va.yaml"
    ENV_FILE = ".env"

    @@env : Hash(String, String)? = nil

    def install_dir : String
      ENV["INSTALL_DIR"]?.presence || DEFAULT_INSTALL_DIR
    end

    def yaml_path : String
      File.join(install_dir, VA_YAML)
    end

    def env_path : String
      File.join(install_dir, ENV_FILE)
    end

    # A node is installed here when its va.yaml is.
    #
    # The .env deliberately does NOT count. It is mode 0600 owned by root on
    # purpose — it holds the FreeSWITCH and licence secrets — so an
    # unprivileged operator cannot see it, and keying off it would report "no
    # node here" on a box that plainly has one.
    def installed? : Bool
      File.exists?(yaml_path)
    end

    # `sed -n 's/^KEY=//p' | head -1` is how install.sh reads this file when it
    # builds the node's `docker run`, so first_wins: on a file with a duplicated
    # key the CLI must resolve to the value the container is actually running
    # with, not to a later one the installer never saw.
    def env : Hash(String, String)
      @@env ||= VoIPAppz::EnvFile.load(env_path, first_wins: true)
    end

    # Unreadable is not the same as empty, and the difference is one `sudo`.
    # A caller that needs a secret out of .env reports this rather than
    # degrading into a confusing failure further down.
    def env_readable? : Bool
      File.exists?(env_path) && File::Info.readable?(env_path)
    end

    # The node's own va.yaml, or nil when nothing is installed here.
    def config : VoIPAppz::DeployConfig?
      return nil unless installed?
      VoIPAppz::DeployConfig.load(yaml_path)
    rescue
      nil
    end

    # WHERE SIP REACHES THIS NODE — `host:port`, from the installed va.yaml.
    #
    # The kamailio SIP address, not a Sofia one: kamailio is the node's front
    # door (`nodes[].profile.sip_port`, 5060 by default) and Sofia's 5070/5090
    # sit behind it. Internal address first — a SIPp run started on the node
    # itself reaches it there, and the external one may be a NAT address this
    # box cannot send to.
    def sip_destination : String?
      node = config.try(&.nodes.first?)
      return nil unless node
      host = node.profile["ip_address_internal"]?.presence ||
             node.profile["ip_address_external"]?.presence
      return nil unless host
      port = node.profile["sip_port"]?.presence || VoIPAppz::NodeEnv::KAMAILIO_SIP_PORT
      "#{host}:#{port}"
    end

    # HOW THIS BOX STARTS ITS NODE, or nil when it has no node to start.
    #
    # Every "it is not running" message in the SIP path used to end in
    # `voipappz up -p voip` — a compose command against the mothership's
    # project, which an installed node does not have and never will. Its
    # container comes from one `docker run`, which is `install.sh --start-only`,
    # which is `make up`. One helper so the advice cannot be right in one
    # message and wrong in the next.
    def start_hint : String?
      return nil unless installed?
      "Installed at #{install_dir} — start it: sudo make up"
    end

    # Specs only: the parse is memoized for the process.
    def reset! : Nil
      @@env = nil
    end
  end
end
