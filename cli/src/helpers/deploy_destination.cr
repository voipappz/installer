require "yaml"

module VoIPAppz
  # A per-server deploy DESTINATION — the Kamal pattern (config/deploy.<dest>.yml)
  # applied to the VoIP stack. Each new PBX gets its own
  # `config/deploy.<name>.yml` holding ONLY the host-specific bits; the class
  # defaults below are the shared "base" (so files stay as small as Kamal's
  # deploy.pbx20.yml). Load + deploy with:
  #
  #     voipappz deploy -d <name>
  #
  # No secrets live here (the registry password + the runtime .env stay
  # out-of-band on the host, like Kamal's /etc/voipappz/secrets.env), so these
  # files are safe to commit — that is the whole point: the fleet of PBX servers
  # is described, reproducibly, by one small committed file each.
  class DeployDestination
    include YAML::Serializable

    # Target host (IP or DNS).
    property host : String
    # SSH connection.
    property user : String = "root"
    property ssh_port : Int32 = 22
    property key : String = "~/.ssh/id_ed25519"
    # Optional domain for kamal-proxy / Kong acme TLS; empty = IP-only.
    property domain : String = ""
    # Skip apt/usermod/ufw provisioning (host already docker-ready, Kamal-style).
    property skip_provision : Bool = false
    # Docker Hub user for the private nirlevi/* images. The PASSWORD is read from
    # ENV["VA_REGISTRY_PASSWORD"] at deploy time and is never committed.
    property registry_username : String = "nirlevi"

    # Resolve config/deploy.<dest>.yml under the project dir.
    def self.path_for(dest : String, project_dir : String) : String
      File.join(project_dir, "config", "deploy.#{dest}.yml")
    end

    def self.load(dest : String, project_dir : String) : DeployDestination
      path = path_for(dest, project_dir)
      unless File.exists?(path)
        raise "Destination file not found: #{path}\n" \
              "Create it (one small file per server, like config/deploy.pbx20.yml):\n" \
              "  host: 1.2.3.4\n  user: ubuntu\n  key: /opt/sw.key"
      end
      from_yaml(File.read(path))
    end

    # Expand a leading ~ in the key path against $HOME.
    def key_path : String
      home = ENV["HOME"]? || ""
      key.gsub("~", home)
    end
  end
end
