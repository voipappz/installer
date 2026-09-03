require "./colors"
require "./project"

# Single source of truth for the service catalog.
# Consumed by `up`, `down`, `status`, `monitor` so each command sees
# identical lists, profiles, ports, and icons.
module VoIPAppz::Services
  # `name`      — compose service key (what `docker compose up <name>` uses).
  # `container` — actual container name from compose `container_name:`.
  #               These are `va-` prefixed and ROLE-named (2026-08-03):
  #               web -> va-app, freeswitch -> va-voip, and the two kamailios
  #               -> va-ingress / va-egress. They deliberately do NOT track
  #               `name`: compose SERVICE names are unchanged because they are
  #               what containers resolve each other by (kong.yaml upstreams
  #               `web:5000`, VA_DATABASE_URL `db:5432`, pgcat, telegraf), so
  #               renaming those would break docker DNS on every deployed node.
  #               Anything doing `docker exec` must resolve through this
  #               catalog (Docker.resolve_container), never guess the name.
  # `profiles`  — every profile the service belongs to. MUST mirror the
  #               `profiles:` list in docker-compose.yaml: `up` starts services
  #               by explicit NAME (see up.cr#voip_services), not by passing
  #               `--profile` to compose, so a service missing from this list
  #               is simply never started for that profile — regardless of what
  #               compose says.
  # `port`      — primary host port, nil if internal-only.
  record Service,
    name : String,
    container : String,
    profiles : Array(String),
    icon : String,
    port : Int32?

  # The catalog is DATA — config/services.tsv — not a constant here.
  #
  # `scripts/check-services.sh` cross-checks it against docker-compose.yaml, and
  # that compose file stays in the stack repo while this code moves to
  # va-crystal (docs/next-cli-boundary.md). A guard that cannot travel with the
  # code has to stop being part of it; the data both sides read is the way to
  # keep one list instead of two that drift.
  CATALOG_FILE = "config/services.tsv"

  ICONS = {
    "box"   => Colors::BOX,
    "net"   => Colors::NET,
    "phone" => Colors::PHONE,
    "gear"  => Colors::GEAR,
    "db"    => Colors::DB,
    "lock"  => Colors::LOCK,
  }

  # A missing catalog is a CONFIGURATION problem, not a crash.
  #
  # `File.read` on an absent catalog raised File::NotFoundError with nothing to
  # catch it, so `voipappz status` — and the console banner, which shells out
  # to it — printed "Unhandled exception" over twenty-four `???` frames and a
  # path the reader has no reason to recognise. That path is wherever
  # Project.root fell back to, which is the actual thing to report.
  class CatalogMissing < Exception
    def initialize(@path : String)
      super("no service catalog at #{@path}\n" \
            "  This command needs the stack project (its docker-compose.yaml and\n" \
            "  config/). Run it from a checkout of that project, from a node where\n" \
            "  `voipappz deploy` installed one, or point VA_PROJECT_DIR at it.")
    end
  end

  @@all : Array(Service)?

  def self.all : Array(Service)
    @@all ||= begin
      path = catalog_path
      raise CatalogMissing.new(path) unless File.exists?(path)
      parse(File.read(path))
    end
  end

  # The catalog is memoized for the process; a spec that changes where the
  # project is has to clear it, exactly as Project.reset! does.
  def self.reset! : Nil
    @@all = nil
  end

  # For a caller that would rather degrade than fail.
  def self.available? : Bool
    File.exists?(catalog_path)
  end

  def self.catalog_path : String
    File.join(VoIPAppz::Project.root, CATALOG_FILE)
  end

  # Pure, so a spec can hand it text.
  # name <TAB> container <TAB> profiles <TAB> icon <TAB> port ("-" = none)
  def self.parse(text : String) : Array(Service)
    services = [] of Service
    text.each_line do |raw|
      line = raw.strip
      next if line.empty? || line.starts_with?('#')
      f = line.split('\t').map(&.strip)
      next if f.size < 5
      port = f[4] == "-" ? nil : f[4].to_i?
      services << Service.new(
        f[0], f[1], f[2].split(',').map(&.strip).reject(&.empty?),
        ICONS[f[3]]? || Colors::BOX, port)
    end
    services
  end

  # `storage` is a real profile (minio + createbuckets), not a synonym for app
  # — but the app plane cannot run without it (web writes recordings to S3), so
  # `up -p app` starts storage too. See up.cr#app_services.
  PROFILES = ["app", "voip", "storage"]

  def self.for_profile(profile : String) : Array(Service)
    profile == "all" ? all : all.select { |s| s.profiles.includes?(profile) }
  end

  # One-shot containers compose starts alongside the app plane. Not in the
  # catalog because they are not long-running services, but a deploy that
  # ignores them verifies a different set than it started.
  INIT_SERVICES = ["createbuckets", "db-init"]

  # COMPOSE profiles to pass to `docker compose --profile ...`.
  #
  # The app plane needs the storage plane — web writes recordings to MinIO —
  # but minio and createbuckets carry `profiles: ["storage"]`, so
  # `--profile app` alone does not start them. Deriving the compose flags and
  # the verification list from the same rule is the point: expecting minio
  # while not starting it would fail a perfectly correct deploy.
  def self.compose_profiles_for(profiles : Array(String)) : Array(String)
    profiles.includes?("app") ? (profiles + ["storage"]).uniq : profiles
  end

  # Everything a deploy of these profiles is expected to bring up.
  #
  # `up` adds two things to the app plane that the catalog does not list: the
  # storage profile (web writes recordings to MinIO, so the app plane cannot
  # run without it) and the init one-shots. Verification has to expect exactly
  # what was started, so it derives the list the same way rather than
  # hardcoding a second one.
  def self.expected_for(profiles : Array(String)) : Array(String)
    # Derived from compose_profiles_for, NOT a second copy of the app->storage
    # rule. These two must agree — verifying a service the deploy never started
    # fails a correct deploy — so one of them owns the implication and the other
    # asks it.
    names = compose_profiles_for(profiles).flat_map { |p| names_for(p) }
    names += INIT_SERVICES if profiles.includes?("app")
    names.uniq
  end

  def self.names_for(profile : String) : Array(String)
    for_profile(profile).map(&.name)
  end

  # Look up by either compose service name or actual container name
  # (matters for `db` ↔ `postgres`).
  def self.find?(key : String) : Service?
    all.find { |s| s.name == key || s.container == key || "va-#{s.container}" == key }
  end
end
