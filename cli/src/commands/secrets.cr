require "admiral"
require "json"
require "../helpers/colors"
require "../helpers/table"
require "../helpers/secrets"
require "../helpers/va_config"
require "../helpers/bao"
require "../helpers/bao_sync"

module VoIPAppz::Commands
  class Secrets < Admiral::Command
    define_help description: "Manage secrets"

    define_flag generate : Bool,
      description: "Generate missing secrets, store in vault",
      default: false,
      short: g
    define_flag validate : Bool,
      description: "Validate all required secrets exist (in vault or locally)",
      default: false,
      short: v
    define_flag sync : Bool,
      description: "Pull secrets FROM OpenBao \u2192 .env (Bao is source of truth)",
      default: false
    define_flag bao_init : Bool,
      description: "Bootstrap OpenBao: init + unseal + enable kv (idempotent)",
      default: false
    define_flag push : Bool,
      description: "Push all infra keys from .env/secrets \u2192 OpenBao",
      default: false
    define_flag bao_status : Bool,
      description: "Show OpenBao seal state + how many keys it holds",
      default: false
    define_flag reset : Bool,
      description: "Regenerate all secrets (DANGEROUS)",
      default: false
    define_flag show : Bool,
      description: "Show secrets (hashed for security)",
      default: false,
      short: s
    define_flag json : Bool,
      description: "Emit machine-readable JSON (presence + hash only \u2014 never values)",
      default: false

    def run
      ENV["VOIPAPPZ_JSON"] = "1" if flags.json

      if flags.json
        emit_json
      elsif flags.generate
        generate_secrets
      elsif flags.validate
        validate_secrets
      elsif flags.bao_init
        bao_init
      elsif flags.push
        bao_push
      elsif flags.bao_status
        bao_show_status
      elsif flags.sync
        sync_secrets
      elsif flags.reset
        reset_secrets
      elsif flags.show
        show_secrets
      else
        # Default: show what's stored
        show_status
      end
    end

    # JSON output is presence-only \u2014 secret values are NEVER emitted.
    # Includes a short hash to detect rotation across snapshots.
    private def emit_json
      entries = VoIPAppz::SecretsHelper.show_hashed.map do |name, hash|
        present = hash != "MISSING"
        {"name" => name, "present" => present, "hash" => present ? hash : nil}
      end
      ok, missing = VoIPAppz::SecretsHelper.validate_env
      payload = {
        "secrets" => entries,
        "summary" => {"total" => entries.size, "missing" => missing, "ok" => ok},
      }
      puts payload.to_json
      exit 2 unless ok
    end

    private def show_status
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::KEY} Secrets Status")
      puts ""

      # Check .env for secret values
      project_dir = VoIPAppz::Docker.project_dir
      env_path = File.join(project_dir, ".env")
      if File.exists?(env_path)
        env_content = File.read(env_path)
        secret_keys = %w[VA_FREESWITCH_PASSWORD VA_S3_KEY VA_S3_SECRET VA_LICENSE_ENCRYPTION_KEY VA_LICENSE_JWT_SECRET]
        found = secret_keys.count { |k| env_content.includes?("#{k}=") }
        puts "  #{VoIPAppz::Colors::KEY}  .env:   #{VoIPAppz::Colors.green("#{found}/#{secret_keys.size} secrets in .env")}"
      else
        puts "  #{VoIPAppz::Colors::KEY}  .env:   #{VoIPAppz::Colors.yellow("not found")}"
      end

      puts ""
      show_secrets
    end

    private def generate_secrets
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::KEY} Generate Secrets")
      puts ""

      project_dir = VoIPAppz::Docker.project_dir

      # Generate secrets and write to .env
      secrets = VoIPAppz::SecretsHelper.generate_all_hash
      config = VoIPAppz::VaConfig.load(project_dir)
      VoIPAppz::VaConfig.write_env(config, project_dir, secrets)
      puts VoIPAppz::Colors.success("Secrets generated and written to .env")

      show_secrets
    end

    private def validate_secrets
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::SHIELD} Validate Secrets")
      puts ""
      errors = [] of String

      # Check .env for required secret values
      project_dir = VoIPAppz::Docker.project_dir
      env_path = File.join(project_dir, ".env")
      if File.exists?(env_path)
        env_content = File.read(env_path)
        # node-lite required secrets
        required = {
          "VA_FREESWITCH_PASSWORD"    => "freeswitch_password",
          "VA_S3_KEY"                 => "s3_key",
          "VA_S3_SECRET"              => "s3_secret",
          "VA_NATS_URL"               => "nats_url",
          "VA_LICENSE_ENCRYPTION_KEY" => "license_encryption_key",
          "VA_LICENSE_JWT_SECRET"     => "license_jwt",
        }
        required.each do |env_key, name|
          if env_content =~ /^#{env_key}=.+$/m
            puts "  #{VoIPAppz::Colors.dot_ok} .env: #{env_key}"
          else
            errors << "Missing in .env: #{env_key}"
            puts "  #{VoIPAppz::Colors.dot_fail} .env missing: #{env_key}"
          end
        end
      else
        errors << ".env file not found"
        puts "  #{VoIPAppz::Colors.dot_fail} .env not found"
      end

      puts ""
      puts VoIPAppz::Colors.divider(50)
      if errors.empty?
        puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} All secrets validated")
      else
        STDERR.puts VoIPAppz::Colors.warning("#{errors.size} issue(s). Run 'voipappz setup --ci' to fix.")
        exit 1
      end
    end

    # --- OpenBao: infra secret store (source of truth) -----------------------
    #
    # The push/dump orchestration (which keys are sensitive, which files make up
    # a host's identity, how .env lines are merged) lives in VoIPAppz::BaoSync
    # so `setup` and `up` reuse the exact same logic. These command methods just
    # add the header/output around it.

    private def bao_init
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::KEY} OpenBao bootstrap")
      puts ""
      ok, msg = VoIPAppz::Bao.init
      unless ok
        STDERR.puts VoIPAppz::Colors.error(msg)
        exit 1
      end
      puts "  #{VoIPAppz::Colors.dot_ok} init:   #{msg}"
      ok, msg = VoIPAppz::Bao.unseal
      unless ok
        STDERR.puts VoIPAppz::Colors.error(msg)
        exit 1
      end
      puts "  #{VoIPAppz::Colors.dot_ok} unseal: #{msg}"
      ok, msg = VoIPAppz::Bao.enable_kv
      unless ok
        STDERR.puts VoIPAppz::Colors.error(msg)
        exit 1
      end
      puts "  #{VoIPAppz::Colors.dot_ok} kv:     #{msg}"
      puts ""
      puts VoIPAppz::Colors.success("OpenBao ready — now run 'voipappz secrets --push' to load keys")
    end

    private def bao_push
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ARROW} Push infra keys → OpenBao")
      puts ""
      st = VoIPAppz::Bao.status
      unless st.running
        STDERR.puts VoIPAppz::Colors.error("openbao is not running — 'voipappz up -p app' then 'secrets --bao-init'")
        exit 1
      end
      if st.sealed
        STDERR.puts VoIPAppz::Colors.error("openbao is sealed — run 'voipappz secrets --bao-init' first")
        exit 1
      end
      if VoIPAppz::BaoSync.sensitive_env_pairs(VoIPAppz::Docker.project_dir).empty? &&
         VoIPAppz::BaoSync.identity_files(VoIPAppz::Docker.project_dir).empty?
        STDERR.puts VoIPAppz::Colors.warning("nothing to push — no .env secrets or identity files found")
        exit 1
      end
      res = VoIPAppz::BaoSync.push(VoIPAppz::Docker.project_dir)
      res.files.each { |rel| puts "  #{VoIPAppz::Colors.dot_ok} #{rel}" }
      puts ""
      puts VoIPAppz::Colors.success("pushed #{res.keys} keys → #{VoIPAppz::Bao::ENV_PATH}, #{res.files.size} file(s) → #{VoIPAppz::Bao::FILES_PREFIX}/")
    end

    private def bao_show_status
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::KEY} OpenBao status")
      puts ""
      st = VoIPAppz::Bao.status
      unless st.running
        puts "  #{VoIPAppz::Colors.dot_fail} container: #{VoIPAppz::Colors.red("not running")}"
        return
      end
      puts "  #{VoIPAppz::Colors.dot_ok} container:   running"
      puts "  #{st.initialized ? VoIPAppz::Colors.dot_ok : VoIPAppz::Colors.dot_fail} initialized: #{st.initialized}"
      sealed_icon = st.sealed ? VoIPAppz::Colors.dot_fail : VoIPAppz::Colors.dot_ok
      puts "  #{sealed_icon} sealed:      #{st.sealed}"
      unless st.sealed
        keys = VoIPAppz::Bao.get_env
        puts "  #{VoIPAppz::Colors::KEY}  keys in Bao:  #{VoIPAppz::Colors.cyan(keys.size.to_s)} (va/env)"
        files = VoIPAppz::Bao.list_files
        puts "  #{VoIPAppz::Colors::KEY}  files in Bao: #{VoIPAppz::Colors.cyan(files.size.to_s)} (#{VoIPAppz::Bao::FILES_PREFIX}/)"
      end
    end

    private def sync_secrets
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::ARROW} Sync secrets  (OpenBao → .env + config/va.yaml)")
      puts ""
      st = VoIPAppz::Bao.status
      if !st.running || st.sealed
        puts VoIPAppz::Colors.info("OpenBao not available (running=#{st.running} sealed=#{st.sealed}).")
        puts VoIPAppz::Colors.info("Secrets stay in .env; bootstrap Bao with 'voipappz secrets --bao-init'.")
        return
      end
      unless VoIPAppz::BaoSync.populated?
        puts VoIPAppz::Colors.warning("OpenBao holds nothing yet — run 'voipappz secrets --push' first")
        return
      end
      res = VoIPAppz::BaoSync.dump(VoIPAppz::Docker.project_dir)
      res.files.each { |rel| puts "  #{VoIPAppz::Colors.dot_ok} #{rel}" }
      puts VoIPAppz::Colors.success("Dumped OpenBao → .env (#{res.keys} keys changed), #{res.files.size} file(s) regenerated")
    end

    private def reset_secrets
      puts VoIPAppz::Colors.error("#{VoIPAppz::Colors::WARN}  WARNING: This will regenerate ALL secrets and break existing deployments!")
      print "Are you sure? (y/N) "
      confirm = gets
      unless confirm && confirm.strip.downcase == "y"
        puts "Cancelled."
        return
      end

      project_dir = VoIPAppz::Docker.project_dir
      secrets = VoIPAppz::SecretsHelper.generate_all_hash(force: true)
      config = VoIPAppz::VaConfig.load(project_dir)
      VoIPAppz::VaConfig.write_env(config, project_dir, secrets)
      puts VoIPAppz::Colors.warning("Secrets regenerated in .env")
      puts VoIPAppz::Colors.warning("You'll need to restart all services")
    end

    private def show_secrets
      columns = [
        VoIPAppz::Table::Column.new("Secret", 28),
        VoIPAppz::Table::Column.new("Hash", 20),
      ]

      rows = VoIPAppz::SecretsHelper.show_hashed.map do |name, hash|
        icon = hash == "MISSING" ? VoIPAppz::Colors::CROSS : VoIPAppz::Colors::KEY
        status = hash == "MISSING" ? VoIPAppz::Colors.red(hash) : VoIPAppz::Colors.cyan(hash)
        ["#{icon}  #{name}", status]
      end

      puts VoIPAppz::Table.render(columns, rows, title: "#{VoIPAppz::Colors::KEY} Secrets (hashed)")
    end
  end
end
