require "./colors"
require "./project"

require "./services"

module VoIPAppz::Docker
  # The compose project, resolved — NOT the current directory. `docker compose`
  # is run with chdir: here, so when this was Dir.current every compose command
  # issued from anywhere but the project root ran in a directory with no
  # docker-compose.yaml and quietly acted on nothing.
  def self.project_dir : String
    VoIPAppz::Project.root
  end
  # Resolved, not assumed to be in the current directory. On a node the binary
  # lives in /opt/cli/bin and the project in /opt/va, so a bare filename made
  # every compose command act on nothing.
  def self.compose_file : String
    VoIPAppz::Project.compose_file
  end
  CI_OVERRIDE      = "docker-compose.ci.yaml"

  PROFILES = {
    "app"  => "app",
    "voip" => "voip",
  }

  class_property ci_mode : Bool = false

  private def self.compose_files : Array(String)
    files = ["-f", compose_file]
    ci_override_path = File.join(project_dir, CI_OVERRIDE)
    if @@ci_mode && File.exists?(ci_override_path)
      files += ["-f", ci_override_path]
    end
    files
  end

  # Explicit "this service lives in THAT container" override.
  #
  #   VA_FREESWITCH_CONTAINER=va-stack-ci voipappz pbx cli -x "sofia status"
  #
  # Role-based resolution below assumes one service per container, named after
  # its role on a deploy node. That assumption does not hold everywhere:
  # va-crystal's test stack runs kamailio, FreeSWITCH and the node together in a
  # single s6-supervised container, and a host can carry a second stack beside
  # the live one. Without an override the CLI resolves `freeswitch` to the
  # production va-voip and an operator command aimed at a test stack lands on
  # the real PBX — the failure mode is silent and bad.
  #
  # One rule for every service: VA_<SERVICE>_CONTAINER, dashes to underscores.
  # That is the same shape sbc.cr already honors for VA_KAMAILIO_EGRESS_CONTAINER
  # and VA_KAMAILIO_INGRESS_CONTAINER, so there is nothing new to remember.
  #
  # Returned unvalidated on purpose: every caller already checks the container
  # is running and names it in the error. Validating here would turn a typo
  # into an exit deep inside a helper instead of "va-typo is not running."
  def self.container_override(service : String) : String?
    key = "VA_#{service.upcase.gsub('-', '_')}_CONTAINER"
    value = ENV[key]?
    return nil unless value
    stripped = value.strip
    stripped.empty? ? nil : stripped
  end

  # The SIP plane merged into one container (2026-08-18): kamailio-egress,
  # freeswitch and node used to be three services on host networking, and are
  # now the single `voip` service. Commands still ask for them by their old
  # role names — `pbx` resolves "freeswitch", `sbc egress` resolves
  # "kamailio-egress" — and those names are the right vocabulary for an
  # operator, so they are mapped here rather than rewritten at every call site.
  #
  # An explicit VA_<SERVICE>_CONTAINER override still wins over this, which is
  # what lets the same commands drive va-crystal's test stack.
  MERGED_INTO_VOIP = {"kamailio-egress", "freeswitch", "node"}

  # Resolve a compose SERVICE name to the actual container name.
  #
  # Container names are `va-` prefixed and role-based (va-app, va-voip,
  # va-ingress, va-egress, ...) while service names are not, so the mapping
  # cannot be derived by prefixing — it comes from the Services catalog.
  # Falls back to "va-<service>" then the bare name so this still works for
  # anything not in the catalog (and for older deployments).
  def self.resolve_container(service : String) : String
    if forced = container_override(service)
      return forced
    end
    containers = running_containers

    # Only when the merged container is actually running, so a node still on
    # the three-container layout resolves the old way and keeps working.
    if MERGED_INTO_VOIP.includes?(service)
      if merged = VoIPAppz::Services.find?("voip").try(&.container)
        return merged if containers.includes?(merged)
      end
    end
    if svc = VoIPAppz::Services.find?(service)
      return svc.container if containers.includes?(svc.container)
    end
    va_name = "va-#{service}"
    if containers.includes?(va_name)
      va_name
    elsif containers.includes?(service)
      service
    else
      # Nothing running under either name: prefer the catalog's container so
      # the error message names what SHOULD be there.
      VoIPAppz::Services.find?(service).try(&.container) || service
    end
  end

  # The SIP plane is two kamailios split by call direction. Most checks apply
  # to whichever one is on this node (an app-only node has just the ingress, a
  # voip-only node just the egress, a combined box both), so they resolve
  # through here instead of hardcoding a name that may not exist.
  KAMAILIO_SERVICES = ["kamailio-ingress", "kamailio-egress"]

  # A node deployed BEFORE the container rename (2026-08-03) has one container
  # called plainly `kamailio`, running the full pre-split config. That config is
  # the SBC — registrar, presence, media, carrier egress — so it is the EGRESS,
  # not the ingress. Recognising it as the ingress would aim SQLite commands at
  # the right box by accident and file-backed ones at it by mistake.
  LEGACY_KAMAILIO = "kamailio"

  # Running kamailio CONTAINER names, ingress first. Empty on a node with none.
  def self.running_kamailios : Array(String)
    # The production image contains the egress Kamailio process itself. There
    # is no daemon to enumerate, but local kamcmd/kamctl are the running egress
    # for every caller that asks this helper.
    return [LOCAL] if local_exec?

    running = running_containers
    found = KAMAILIO_SERVICES.compact_map do |svc|
      c = VoIPAppz::Services.find?(svc).try(&.container)
      c if c && running.includes?(c)
    end
    # Only when neither new-style container is present: on a mixed node the
    # real ones win, and a stray legacy name must not shadow them.
    found << LEGACY_KAMAILIO if found.empty? && running.includes?(LEGACY_KAMAILIO)
    found
  end

  # First running kamailio, or nil. For checks that just need "a" kamailio.
  def self.running_kamailio? : String?
    running_kamailios.first?
  end

  # Container name of the INGRESS specifically.
  #
  # The two kamailios do not have the same storage: the ingress is file-backed
  # (config/kamailio/ingress/dispatcher.list) and the egress is SQLite-backed, so
  # anything that WRITES has to know which one it is talking to. Reads are
  # still interchangeable.
  def self.ingress_container : String?
    # INSIDE THE NODE IMAGE THERE IS NO INGRESS, and no catalog to ask about
    # one: the ingress belongs to the app plane, which is a different machine,
    # and the image stopped shipping /stack (and its config/services.tsv) on
    # 2026-08-26. Without this, `sbc egress sync` resolves its kamailio to
    # LOCAL correctly and then dies on `ingress?(LOCAL)` with CatalogMissing —
    # which reads as "this command needs the stack project" on the one box
    # where the stack project is deliberately absent.
    return nil if local_exec?
    VoIPAppz::Services.find?("kamailio-ingress").try(&.container)
  end

  # The legacy `kamailio` container is deliberately NOT the ingress — see
  # LEGACY_KAMAILIO. It answers false here, so it is treated as the egress and
  # SQLite-backed commands reach it, which is what that config actually has.
  def self.ingress?(container : String) : Bool
    container == ingress_container
  end

  # Get the host port mapped to a container's internal port using docker port
  def self.mapped_port(service : String, internal_port : Int32) : Int32
    container = resolve_container(service)
    stdout = IO::Memory.new
    process = Process.new(
      "docker",
      ["port", container, internal_port.to_s],
      output: stdout,
      error: Process::Redirect::Close,
    )
    process.wait
    result = stdout.to_s.strip.split("\n").first? || ""
    if result =~ /:(\d+)$/
      $1.to_i
    else
      internal_port
    end
  rescue
    internal_port
  end

  # COMPOSE IS NOT EXEMPT FROM THE DOCKER CHECK, and `ensure_docker!` is —
  # it returns early under local_exec?, which is the mode the CLI runs in
  # INSIDE the voip image (it finds kamctl on PATH and drives kamailio and
  # FreeSWITCH directly, with no daemon to ask). That exemption is right for
  # `exec`: a per-container command has a local equivalent there. It is wrong
  # here, because `docker compose` has none — the node container holds one
  # service and cannot see the plane.
  #
  # So `voipappz status` inside a node reached Process.new("docker", ...) with
  # no docker binary and died with an unhandled
  # `Error executing process: 'docker': No such file or directory` over
  # nineteen `???` frames.
  # The seam the spec drives: local_exec? and this must be able to disagree.
  # Before ensure_compose! existed they could not — the compose path asked
  # ensure_docker!, which answers "fine" for anything local.
  def self.compose_available? : Bool
    @@docker_checked || !Process.find_executable("docker").nil?
  end

  def self.reset_docker_check!
    @@docker_checked = false
  end

  def self.ensure_compose! : Nil
    return if compose_available?
    STDERR.puts VoIPAppz::Colors.red("docker not found on PATH.")
    if local_exec?
      STDERR.puts VoIPAppz::Colors.dim(
        "  This command drives the whole compose plane, and you are inside one of\n" \
        "  its containers — there is no docker daemon here, deliberately. Run it\n" \
        "  from the host that runs this node.")
    else
      STDERR.puts VoIPAppz::Colors.dim(
        "  This command talks to the local container stack — install docker, or run it on the node.")
    end
    exit 1
  end

  def self.compose(args : Array(String), capture : Bool = false) : {Int32, String}
    ensure_compose!
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    process = Process.new(
      "docker",
      ["compose"] + compose_files + args,
      chdir: project_dir,
      output: capture ? stdout : Process::Redirect::Inherit,
      error: capture ? stderr : Process::Redirect::Inherit,
    )
    status = process.wait

    {status.exit_code, stdout.to_s}
  end

  def self.compose!(args : Array(String)) : Nil
    exit_code, _ = compose(args)
    if exit_code != 0
      files = compose_files.join(" ")
      STDERR.puts Colors.red("Command failed: docker compose #{files} #{args.join(" ")}")
      exit exit_code
    end
  end

  def self.compose_profiles(profiles : Array(String), args : Array(String), capture : Bool = false) : {Int32, String}
    profile_args = profiles.flat_map { |p| ["--profile", p] }
    compose(profile_args + args, capture: capture)
  end

  def self.compose_profiles!(profiles : Array(String), args : Array(String)) : Nil
    exit_code, _ = compose_profiles(profiles, args)
    if exit_code != 0
      files = compose_files.join(" ")
      STDERR.puts Colors.red("Command failed: docker compose #{files} #{args.join(" ")}")
      exit exit_code
    end
  end

  # Every docker-touching command funnels through exec/compose, so the "docker
  # is not installed" case is checked once here. Without it a missing binary
  # surfaced as an unhandled File::NotFoundError with a Crystal backtrace —
  # which reads like a CLI bug rather than a missing dependency.
  @@docker_checked = false

  # Running INSIDE the node, where `docker exec` is the wrong verb: kamctl,
  # fs_cli and sqlite3 are processes in this container and there is no daemon
  # to ask.
  #
  # Detected, not declared. "Am I in a container?" is the wrong question —
  # /.dockerenv is true in two situations that need opposite behaviour: inside
  # the voip image (kamctl is here) and inside a CI job container that mounts
  # the host's docker socket to drive the stack (kamctl is not, and docker is
  # exactly right). What separates them is whether the tools are on this box,
  # so that is what is asked.
  #
  # kamctl specifically: it ships in the voip image and on no workstation that
  # is not running kamailio natively. Resolved once — a PATH does not change
  # under a running command.
  @@local_exec : Bool? = nil

  def self.local_exec? : Bool
    cached = @@local_exec
    return cached unless cached.nil?
    @@local_exec = !Process.find_executable("kamctl").nil?
  end

  # Specs only: the cache is per-process and a spec that moves PATH has to be
  # able to ask again.
  def self.reset_local_exec!
    @@local_exec = nil
  end

  # The name for "this box", so callers keep passing a container around and
  # their messages still read sensibly. Every exec ignores it.
  LOCAL = "local"

  def self.ensure_docker!
    return if local_exec?
    return if @@docker_checked
    if Process.find_executable("docker").nil?
      STDERR.puts VoIPAppz::Colors.red("docker not found on PATH.")
      STDERR.puts VoIPAppz::Colors.dim("  This command talks to the local container stack — install docker, or run it on the node.")
      exit 1
    end
    @@docker_checked = true
  end

  def self.exec(container : String, cmd : Array(String), capture : Bool = true) : {Int32, String}
    return exec_local(cmd, capture) if local_exec?

    ensure_docker!
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    process = Process.new(
      "docker",
      ["exec", container] + cmd,
      output: capture ? stdout : Process::Redirect::Inherit,
      error: capture ? stderr : Process::Redirect::Inherit,
    )
    status = process.wait

    {status.exit_code, stdout.to_s.strip}
  end

  # The same command, run here. Same return shape, so no caller changes.
  def self.exec_local(cmd : Array(String), capture : Bool = true) : {Int32, String}
    return {127, ""} if cmd.empty?

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    process = Process.new(
      cmd[0], cmd[1..],
      output: capture ? stdout : Process::Redirect::Inherit,
      error: capture ? stderr : Process::Redirect::Inherit,
    )
    status = process.wait

    {status.exit_code, stdout.to_s.strip}
  rescue File::NotFoundError
    # Missing here means the CLI is running somewhere that is not a node.
    {127, ""}
  end

  def self.exec_t(container : String, cmd : Array(String), capture : Bool = true) : {Int32, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    process = Process.new(
      "docker",
      ["compose"] + compose_files + ["exec", "-T", container] + cmd,
      chdir: project_dir,
      output: capture ? stdout : Process::Redirect::Inherit,
      error: capture ? stderr : Process::Redirect::Inherit,
    )
    status = process.wait

    {status.exit_code, stdout.to_s.strip}
  end

  def self.ps(capture : Bool = false) : {Int32, String}
    ensure_docker!
    # Containers in this stack use bare names (postgres, redis, kong, ...)
    # via container_name in docker-compose.yaml — no project prefix to filter on.
    stdout = IO::Memory.new
    process = Process.new(
      "docker",
      ["ps", "--format", "table {{.Names}}\t{{.Status}}\t{{.Ports}}"],
      output: capture ? stdout : Process::Redirect::Inherit,
      error: Process::Redirect::Close,
    )
    status = process.wait
    {status.exit_code, stdout.to_s}
  end

  def self.running_containers : Array(String)
    # Inside the node one container runs and it is this one. Answering LOCAL
    # lets resolution run UNCHANGED — the image's override names LOCAL, the
    # membership check finds it, and no command needs a special case.
    return [LOCAL] if local_exec?

    ensure_docker!
    stdout = IO::Memory.new
    process = Process.new(
      "docker",
      ["ps", "--format", "{{.Names}}"],
      output: stdout,
      error: Process::Redirect::Close,
    )
    process.wait
    stdout.to_s.strip.split("\n").reject(&.empty?)
  end

  def self.stats(capture : Bool = false) : {Int32, String}
    ensure_docker!
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    containers = running_containers
    return {0, "No containers running"} if containers.empty?

    process = Process.new(
      "docker",
      ["stats", "--no-stream", "--format", "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"] + containers,
      output: capture ? stdout : Process::Redirect::Inherit,
      error: capture ? stderr : Process::Redirect::Inherit,
    )
    status = process.wait

    {status.exit_code, stdout.to_s}
  end

  def self.kill_all : Nil
    stdout = IO::Memory.new
    process = Process.new("docker", ["ps", "-q"], output: stdout, error: Process::Redirect::Close)
    process.wait
    ids = stdout.to_s.strip
    unless ids.empty?
      Process.new("docker", ["kill"] + ids.split("\n"), output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).wait
    end
  end
end
