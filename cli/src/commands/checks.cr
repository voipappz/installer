require "admiral"
require "../helpers/colors"
require "../helpers/deploy_manifest"
require "../helpers/deploy_config"
require "../helpers/docker"
require "../helpers/sip"
require "../helpers/va_config"

module VoIPAppz::Commands
  # Repo gate — replaces the CircleCI validate-config + security-scan stages
  # with a local command usable everywhere the same way (the repo rule: one
  # implementation, many entry points): by hand, from `voipappz console`, as a
  # git pre-push hook (--install-hook), or as a Kamal pre-deploy hook.
  # Accumulates ALL failures before exiting non-zero (fail fast, report all).
  class Checks < Admiral::Command
    define_help description: "Repo checks: compose, secret hygiene, manifest (pre-push gate)"
    define_flag install_hook : Bool, description: "Install as .git/hooks/pre-push and exit", default: false

    # Paths that must never be tracked: live secrets and customer-identifying
    # host config. (.gitignore covers new files; this catches already-tracked.)
    FORBIDDEN_TRACKED = [/^secrets\//, /^\.env$/, /^config\/va\.yaml$/, /^voipappz\.yaml$/, /^data\//]

    def run
      return do_install_hook if flags.install_hook

      errors = [] of String
      check_tracked_hygiene(errors)
      check_hardcoded_secrets(errors)
      check_compose(errors)
      check_manifest(errors)
      check_va_yaml(errors)
      check_sip(errors)
      # KEMI lua hooks live in config/kamailio/lua/ behind -A WITH_LUA and are covered
      # by their own mock-KSR suite (config/kamailio/lua/spec, run in CI).

      puts ""
      if errors.empty?
        puts VoIPAppz::Colors.success("All checks passed")
      else
        errors.each { |e| STDERR.puts VoIPAppz::Colors.red("  ✘ #{e}") }
        STDERR.puts VoIPAppz::Colors.red("#{errors.size} check failure(s)")
        exit 1
      end
    end

    private def step(name : String, ok : Bool, detail : String = "")
      mark = ok ? VoIPAppz::Colors.green("ok") : VoIPAppz::Colors.red("FAIL")
      puts "  #{name.ljust(34)} #{mark}#{detail.empty? ? "" : " #{VoIPAppz::Colors.dim(detail)}"}"
    end

    private def git(args : Array(String)) : {Int32, String}
      io = IO::Memory.new
      st = Process.run("git", args, output: io, error: io)
      {st.exit_code, io.to_s}
    end

    # 1. No live secrets / customer config tracked in git.
    private def check_tracked_hygiene(errors : Array(String))
      _, out = git(["ls-files"])
      bad = out.lines.map(&.strip).select { |f| FORBIDDEN_TRACKED.any?(&.matches?(f)) }
      step("tracked-file hygiene", bad.empty?)
      bad.each { |f| errors << "tracked file must be untracked + gitignored: #{f}" }
    end

    # 2. No hardcoded credentials in tracked text files. Tracked-only via
    # `git grep`; templates/examples/specs/docs excluded; templated values
    # ($VAR, <%, ${...}) and obvious placeholders allowlisted.
    private def check_hardcoded_secrets(errors : Array(String))
      code, out = git(["grep", "-nIiE",
        %q{(password|secret|token|api_key)["']?\s*[:=]\s*["'][A-Za-z0-9+/_\-]{12,}},
        "--", ":!*.template", ":!*.example", ":!*.md", ":!cli/spec", ":!*.lock"])
      hits = [] of String
      if code == 0
        out.each_line do |line|
          next if line =~ /\$\{|\$[A-Z_]|<%|getenv|ENV\[|example|changeme|placeholder|REPLACE/i
          hits << line.strip
        end
      end
      step("hardcoded-secret scan", hits.empty?)
      hits.first(10).each { |h| errors << "possible hardcoded secret: #{h[0, 120]}" }
    end

    # 3. docker-compose.yaml parses with the current .env (skipped if no docker).
    private def check_compose(errors : Array(String))
      unless Process.find_executable("docker")
        step("compose config", true, "(skipped — no docker)")
        return
      end
      io = IO::Memory.new
      st = Process.run("docker", ["compose", "-f", "docker-compose.yaml", "config", "-q"], output: io, error: io)
      step("compose config", st.success?)
      errors << "docker compose config failed: #{io.to_s.lines.first?}" unless st.success?
    end

    # 4. Deploy-manifest invariants (same rules as cli/spec/deploy_manifest_spec):
    # every config bind-mount is in FILES, no dev-tree absolute mounts, and
    # every FILES entry exists on disk.
    private def check_manifest(errors : Array(String))
      compose = File.read("docker-compose.yaml")
      missing = VoIPAppz::DeployManifest.missing_from_manifest(compose)
      devmnt = VoIPAppz::DeployManifest.dev_source_mounts(compose)
      # Host-generated files (.env, config/va.yaml) are gitignored — absent in a
      # checkout/CI by design — so don't require them on disk here.
      absent = VoIPAppz::DeployManifest.files.keys.reject do |f|
        VoIPAppz::DeployManifest.host_generated.includes?(f) || File.exists?(f)
      end
      ok = missing.empty? && devmnt.empty? && absent.empty?
      step("deploy manifest", ok)
      missing.each { |m| errors << "compose mount not in config/deploy-manifest.tsv: #{m}" }
      devmnt.each { |m| errors << "dev-tree absolute mount in compose: #{m}" }
      absent.each { |f| errors << "manifest file missing on disk: #{f}" }
    rescue ex
      step("deploy manifest", false)
      errors << "manifest check failed: #{ex.message}"
    end

    # 5. config/va.yaml (host-local, untracked) must still parse — catches the
    # YAML schema crashes (e.g. structured gateways on an old binary).
    # Live SIP OPTIONS against the local kamailio. Self-skips when kamailio is
    # not running so the repo gate still passes in a bare CI checkout — same
    # pattern as the compose check. When kamailio IS up this is a real
    # transaction on the wire, not a process-liveness probe.
    private def check_sip(errors : Array(String))
      # The repo-gate CI job runs in a bare container with no docker binary at
      # all; skip there exactly like check_compose does, so the gate stays a
      # pure repo check. The integration job (docker present, stack up) is
      # where this actually exercises the wire.
      if Process.find_executable("docker").nil?
        step("SIP OPTIONS", true, "skipped — no docker")
        return
      end
      if VoIPAppz::Docker.running_kamailio?.nil?
        step("SIP OPTIONS", true, "skipped — no kamailio running")
        return
      end
      host = VoIPAppz::SIP.default_host
      port = VoIPAppz::SIP.default_port
      response = VoIPAppz::SIP.options(host, port)
      step("SIP OPTIONS", !response.nil?,
        response ? "SIP #{response.status} #{response.reason} (#{host}:#{port})" : "no reply on #{host}:#{port}")
      errors << "kamailio did not answer SIP OPTIONS on #{host}:#{port}" unless response
    rescue ex
      step("SIP OPTIONS", false, ex.message || ex.class.to_s)
      errors << "SIP OPTIONS check failed: #{ex.message}"
    end

    private def check_va_yaml(errors : Array(String))
      path = VoIPAppz::VaConfig.yaml_path(VoIPAppz::Docker.project_dir)
      unless File.exists?(path)
        step("va.yaml parse", true, "(absent — run `voipappz setup`)")
        return
      end
      config = VoIPAppz::DeployConfig.load(path)
      step("va.yaml parse", true)
      check_va_yaml_inline_secrets(config, errors)
    rescue ex
      step("va.yaml parse", false)
      errors << "#{path} does not parse: #{ex.message.to_s.lines.first?}"
    end

    # 5b. Secret VALUES must live in the process environment/vault, never in
    # the world-readable node YAML.
    private def check_va_yaml_inline_secrets(config : VoIPAppz::DeployConfig,
                                             errors : Array(String))
      leaks = [] of String
      p = config.organization.profile
      leaks << "organization.profile.smtp_password" unless p.smtp_password.empty?
      # smtp_username is an AWS access-key id when using SES — treat as secret.
      leaks << "organization.profile.smtp_username" unless p.smtp_username.empty?
      process_only = VoIPAppz::NodeEnv::PROCESS_ONLY_ENV_KEYS.select do |key|
        config.env.has_key?(key)
      end

      clean = leaks.empty? && process_only.empty?
      count = leaks.size + process_only.size
      step("va.yaml inline-secret scan", clean,
        clean ? "" : "(#{count} inline secret value(s))")
      unless leaks.empty?
        STDERR.puts VoIPAppz::Colors.yellow(
          "  ⚠ inline secret VALUES in config/va.yaml — move to vault/.env:")
        leaks.each { |k| STDERR.puts VoIPAppz::Colors.yellow("      #{k}") }
        STDERR.puts VoIPAppz::Colors.dim(
          "    (va.yaml is gitignored, but secrets belong in `secrets: {source: vault}`)")
        leaks.each { |key| errors << "#{key} must not be stored in va.yaml" }
      end

      process_only.each do |key|
        errors << "#{key} must be passed in the process environment, never stored in va.yaml"
      end
    end


    private def do_install_hook
      hook = ".git/hooks/pre-push"
      unless Dir.exists?(".git")
        STDERR.puts VoIPAppz::Colors.red("not a git repository root")
        exit 1
      end
      File.write(hook, <<-SH)
        #!/bin/sh
        # voipappz pre-push gate — installed by `voipappz checks --install-hook`.
        bin="$(git rev-parse --show-toplevel)/cli/bin/voipappz"
        [ -x "$bin" ] || { echo "voipappz binary missing — run cli/build.sh" >&2; exit 1; }
        exec "$bin" checks
        SH
      File.chmod(hook, 0o755)
      puts VoIPAppz::Colors.success("installed #{hook} — every `git push` now runs `voipappz checks`")
    end
  end
end
