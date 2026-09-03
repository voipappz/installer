module VoIPAppz
  # Host bootstrap — the Kamal `server bootstrap` approach, implemented in Crystal
  # (not shelling out to kamal) so the VoIP-stack deploy provisions a fresh host
  # identically. Pure functions return the shell command to run over SSH (same
  # shape as VoIPAppz::Topology), so they are unit-testable.
  module Bootstrap
    extend self

    # Official, distro-agnostic Docker install — exactly what `kamal server
    # bootstrap` runs. https://get.docker.com installs docker-ce + the compose v2
    # plugin on Ubuntu/Debian/CentOS/… (vs apt's old docker.io + a separate
    # compose v1 that the rest of the stack doesn't use).
    DOCKER_INSTALL_URL = "https://get.docker.com"

    # Idempotent: skip if docker is already present. Wrapped in `bash -c` so the
    # entire `||` chain runs as ONE command (under sudo via ssh_run!) — ssh_run!
    # only sudo-prefixes the first command in a chain, so without the wrapper the
    # curl|sh install would run unprivileged and fail.
    def install_docker_cmd : String
      "bash -c 'which docker > /dev/null 2>&1 || " \
      "{ curl -fsSL #{DOCKER_INSTALL_URL} -o /tmp/get-docker.sh && " \
      "sh /tmp/get-docker.sh && rm -f /tmp/get-docker.sh; }'"
    end

    # Enable + start dockerd on systemd hosts; no-op elsewhere (also what Kamal
    # does — the convenience script enables the service, this is the belt-and-
    # suspenders for hosts where it didn't).
    def enable_docker_cmd : String
      "bash -c 'command -v systemctl > /dev/null 2>&1 && " \
      "systemctl enable --now docker || echo no-systemd-skipping'"
    end

    # Let the deploy user run docker without sudo after the next login (Kamal
    # adds the SSH user to the docker group the same way).
    def add_user_to_docker_group_cmd(user : String) : String
      "usermod -aG docker #{user}"
    end
  end
end
