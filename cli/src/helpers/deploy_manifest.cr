require "./project"

module VoIPAppz
  # Single source of truth for which repo files `voipappz deploy` provisions to
  # a remote host, plus pure helpers that cross-check the docker-compose bind
  # mounts against that manifest.
  #
  # Why this exists: on pbx20 (2026-06-04/05) two services came up broken
  # because a bind-mount source did not exist on the target, so Docker silently
  # created an **empty directory** and mounted it *over* the image's baked
  # config:
  #   * FreeSWITCH — dev-tree mounts of `/opt/src/va-voipbox-freeswitch/conf/*`
  #     (removed; the :2026 image ships its own config).
  #   * Kamailio  — `./kamailio.lua` (the KEMI routing script) was bind-mounted
  #     by compose but MISSING from the deploy manifest, so it was never copied
  #     to `/opt/va` → `/etc/kamailio/kamailio.lua` was an empty dir.
  #
  # The pure functions below let a spec assert these can't regress:
  #   * every relative config-file bind-mount in docker-compose.yaml is in FILES
  #   * docker-compose.yaml has no un-allowlisted absolute (dev-tree) mounts
  #
  # Functions take the compose text as a parameter (not read from disk) so they
  # stay deterministic and unit-testable — same shape as `VoIPAppz::Topology`.
  module DeployManifest
    extend self

    # The manifest is DATA — config/deploy-manifest.tsv — not a constant here.
    #
    # It describes THIS STACK (which configs this compose file needs on a node),
    # not the tool doing the copying. `deploy` is becoming shell and the CLI is
    # moving to va-crystal (docs/next-cli-boundary.md); both sides read the same
    # file rather than each holding a list that drifts from the other.
    # `scripts/check-deploy-manifest.sh` reads it too, which is what keeps the
    # pbx20 empty-dir-clobber invariant enforced once this code has moved out.
    MANIFEST_FILE = "config/deploy-manifest.tsv"

    # Absolute path to the manifest, resolved against the project the same way
    # every other repo file is — a node runs the binary from outside the tree.
    def manifest_path : String
      File.join(VoIPAppz::Project.root, MANIFEST_FILE)
    end

    # repo-relative path => absolute path on the deploy target.
    def files : Hash(String, String)
      @@files ||= parse(read_manifest)[:files]
    end

    # Host-generated, gitignored files (also in checks' FORBIDDEN_TRACKED): they
    # exist only after `voipappz setup` ON THE HOST, never in a repo checkout or
    # in CI. Still bind-mounted and shipped, but must NOT be required on disk by
    # the manifest's existence check.
    def host_generated : Array(String)
      @@host_generated ||= parse(read_manifest)[:host_generated]
    end

    @@files : Hash(String, String)?
    @@host_generated : Array(String)?

    private def read_manifest : String
      path = manifest_path
      unless File.exists?(path)
        raise "deploy manifest not found at #{path} — it ships with the repo; \
run from a checkout or set VA_PROJECT_DIR"
      end
      File.read(path)
    end

    # Pure, so a spec can hand it text — same shape as the compose helpers
    # below. Tab-separated: source, target, optional comma-separated flags.
    def parse(text : String) : NamedTuple(files: Hash(String, String), host_generated: Array(String))
      files = {} of String => String
      host  = [] of String
      text.each_line do |raw|
        line = raw.strip
        next if line.empty? || line.starts_with?('#')
        parts = line.split('\t').map(&.strip).reject(&.empty?)
        next if parts.size < 2
        src, dst = parts[0], parts[1]
        files[src] = dst
        if parts.size > 2 && parts[2].split(',').map(&.strip).includes?("host-generated")
          host << src
        end
      end
      {files: files, host_generated: host}
    end

    # A bind-mount whose source ends in one of these is a *config file* the host
    # must have on disk (vs. a runtime data dir like `./data/kamailio`).
    CONFIG_EXTS = [".cfg", ".lua", ".yaml", ".yml", ".conf", ".toml", ".sh", ".sql", ".xml", ".json", ".list"]

    # Absolute host paths that are legitimately mounted (provided by the host
    # OS / docker), so they are not "dev-tree" mounts and don't need shipping.
    # /tmp entries: the API (web) service mounts host /tmp as scratch/report
    # space (from the va-installer compose). /tmp always exists on a host and
    # these are runtime data dirs, not config — no empty-dir-clobber risk.
    # /proc: telegraf mounts host /proc (read-only) for system metrics — always
    # present on a Linux host, like /etc/localtime; not a dev-tree mount.
    ABS_MOUNT_ALLOWLIST = ["/etc/localtime", "/etc/timezone", "/var/run/docker.sock", "/tmp/", "/tmp/reports", "/proc"]

    # Source side of a compose volume line, or nil if the line isn't a volume.
    # Handles `      - ./a.cfg:/etc/a.cfg:ro` and `- /etc/localtime:/...:ro`.
    private def mount_source(line : String) : String?
      l = line.strip
      return nil unless l.starts_with?("- ")
      spec = l[2..].strip
      # Named volumes (e.g. `recordings:/path`) and options aren't host paths.
      return nil unless spec.starts_with?("./") || spec.starts_with?("/")
      spec.split(':').first
    end

    # Relative `./<file>` bind-mount sources that look like config files.
    # Returns repo-relative paths (leading `./` stripped), de-duplicated.
    def config_file_mounts(compose_text : String) : Array(String)
      mounts = [] of String
      compose_text.each_line do |line|
        src = mount_source(line)
        next unless src && src.starts_with?("./")
        rel = src[2..]
        next unless CONFIG_EXTS.any? { |ext| rel.ends_with?(ext) }
        mounts << rel
      end
      mounts.uniq
    end

    # Config-file bind-mounts that the deploy would NOT copy to the host.
    # Must be empty — anything here becomes an empty-dir clobber on the target.
    def missing_from_manifest(compose_text : String) : Array(String)
      config_file_mounts(compose_text).reject { |m| files.has_key?(m) }
    end

    # Absolute bind-mount sources that aren't in the allowlist — i.e. dev-tree
    # mounts (like `/opt/src/...`) that won't exist on a deploy target.
    def dev_source_mounts(compose_text : String) : Array(String)
      mounts = [] of String
      compose_text.each_line do |line|
        src = mount_source(line)
        next unless src && src.starts_with?("/")
        next if ABS_MOUNT_ALLOWLIST.includes?(src)
        mounts << src
      end
      mounts.uniq
    end
  end
end
