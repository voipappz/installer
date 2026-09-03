require "admiral"
require "../helpers/colors"
require "../helpers/docker"

module VoIPAppz::Commands
  # `voipappz cert` — TLS certificates. acme.sh owns issuance and renewal.
  #
  # Flow (per docker-compose.yaml `acmesh`):
  #   1. acme.sh runs in `daemon` mode and issues/auto-renews over DNS-01: it
  #      writes the TXT record into OUR Cloudflare zone (VA_ACME_ALIAS) using
  #      CF_Token. The customer's DNS host needs no API — just a one-time
  #      static CNAME _acme-challenge.<VA_DOMAIN> -> _acme-challenge.<alias>.
  #      Nothing is fetched over HTTP, so ports 80/443 can stay firewalled.
  #   2. The installed cert lands on the shared ./certs volume as
  #      server.{crt,key} (Kong's KONG_SSL_CERT) and tls.{crt,key} (kamailio's
  #      tls.cfg). The install's reloadcmd mirrors server.* -> tls.* so a
  #      daemon-driven renewal refreshes both without the CLI.
  #   3. Kong does NOT issue anything — its bundled `acme` plugin was removed
  #      2026-07-29. It serves certs/server.* and the daily ofelia
  #      `cert-reload` job runs `kong reload` to pick up a renewal.
  #
  # Subcommands:
  #   voipappz cert            # status — acme.sh state + certs on disk
  #   voipappz cert --issue    # issue via DNS-01, install, reload the edge
  #   voipappz cert --sync     # re-install the current acme.sh cert + reload
  #   voipappz cert --domain X # override the domain (defaults to VA_DOMAIN)
  class Cert < Admiral::Command
    define_help description: "Manage TLS certificates (acme.sh, DNS-01)"

    define_flag issue : Bool,
      description: "Issue/renew the cert via acme.sh DNS-01, then install and reload",
      default: false
    define_flag sync : Bool,
      description: "Re-install acme.sh's current cert → certs/server.* + certs/tls.*, reload Kong + kamailio",
      default: false
    define_flag force : Bool,
      description: "With --issue: pass --force so acme.sh reissues even if the cert is still fresh",
      default: false
    define_flag domain : String,
      description: "Domain to inspect or issue (defaults to VA_DOMAIN from .env)",
      default: ""

    ACME_CONTAINER = "acmesh"
    # acme.sh's view of the shared ./certs volume (compose mounts it at /out).
    OUT_DIR = "/out"

    def run
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::LOCK} TLS Certificate (acme.sh / DNS-01)")
      puts ""

      env = load_env
      domain = flags.domain.empty? ? (env["VA_DOMAIN"]? || "").strip : flags.domain

      print_status(domain, env)

      if flags.issue
        if domain.empty?
          STDERR.puts VoIPAppz::Colors.error("No domain to issue — pass --domain X or set VA_DOMAIN in .env")
          exit 1
        end
        issue_cert(domain, env)
        install_cert(domain)
        reload_edge
      elsif flags.sync
        if domain.empty?
          STDERR.puts VoIPAppz::Colors.error("No domain to sync — pass --domain X or set VA_DOMAIN in .env")
          exit 1
        end
        install_cert(domain)
        reload_edge
      end
    end

    # --- status -------------------------------------------------------------

    private def print_status(domain : String, env : Hash(String, String))
      if domain.empty?
        puts "  #{VoIPAppz::Colors.dot_fail} #{VoIPAppz::Colors::NET}  Domain:             #{VoIPAppz::Colors.dim("unset (VA_DOMAIN) — IP-only, self-signed TLS")}"
      else
        puts "  #{VoIPAppz::Colors.dot_ok} #{VoIPAppz::Colors::NET}  Domain:             #{VoIPAppz::Colors.cyan(domain)}"
        alias_zone = (env["VA_ACME_ALIAS"]? || "acme.voipappz.io").strip
        puts "     #{VoIPAppz::Colors.dim("dns:")}      #{(env["VA_ACME_DNS"]? || "dns_cf").strip}"
        puts "     #{VoIPAppz::Colors.dim("alias:")}    _acme-challenge.#{domain} #{VoIPAppz::Colors::ARROW} _acme-challenge.#{alias_zone}"
      end

      if acmesh_running?
        puts "  #{VoIPAppz::Colors.dot_ok} #{VoIPAppz::Colors::CHECK}  acme.sh daemon:     #{VoIPAppz::Colors.green("running")}"
        token = ENV["VA_CF_TOKEN"]? || env["VA_CF_TOKEN"]?
        if token.nil? || token.strip.empty?
          puts "  #{VoIPAppz::Colors.dot_fail} #{VoIPAppz::Colors::KEY}  Cloudflare token:   #{VoIPAppz::Colors.red("VA_CF_TOKEN unset — DNS-01 issuance will fail")}"
        end
        print_acme_list
      else
        puts "  #{VoIPAppz::Colors.dot_fail} #{VoIPAppz::Colors::CHECK}  acme.sh daemon:     #{VoIPAppz::Colors.red("not running")} #{VoIPAppz::Colors.dim("(docker compose --profile app up -d acmesh)")}"
      end

      puts ""
      describe_cert("Kong  (server.*)", "server")
      describe_cert("egress   (tls.*)", "tls")
      puts ""
    end

    private def acmesh_running? : Bool
      VoIPAppz::Docker.running_containers.includes?(ACME_CONTAINER)
    end

    # `acme.sh --list` prints one row per managed domain with its renew date.
    private def print_acme_list
      exit_code, output = VoIPAppz::Docker.exec(ACME_CONTAINER, ["acme.sh", "--list"])
      lines = output.strip.lines.reject(&.strip.empty?)
      if exit_code != 0 || lines.size <= 1
        puts "  #{VoIPAppz::Colors.dot_fail} #{VoIPAppz::Colors::CLOCK}  Issued cert:        #{VoIPAppz::Colors.dim("none yet — run `voipappz cert --issue`")}"
        return
      end
      puts "  #{VoIPAppz::Colors.dot_ok} #{VoIPAppz::Colors::CHECK}  acme.sh inventory:"
      lines.each { |l| puts "     #{VoIPAppz::Colors.dim(l)}" }
    end

    # Report what is actually on disk — that, not acme.sh's bookkeeping, is
    # what Kong and kamailio serve. A self-signed placeholder (issuer ==
    # subject) is called out explicitly: it means acme.sh has not installed
    # a real cert yet, which is easy to miss since TLS still "works".
    private def describe_cert(label : String, stem : String)
      crt = File.join(VoIPAppz::Docker.project_dir, "certs", "#{stem}.crt")
      key = File.join(VoIPAppz::Docker.project_dir, "certs", "#{stem}.key")
      unless File.exists?(crt) && File.exists?(key)
        puts "  #{VoIPAppz::Colors.dot_fail} #{VoIPAppz::Colors::LOCK}  #{label}:   #{VoIPAppz::Colors.red("missing")}"
        return
      end

      subject = openssl_field(crt, "-subject")
      issuer = openssl_field(crt, "-issuer")
      enddate = openssl_field(crt, "-enddate")
      self_signed = !subject.empty? && subject.lchop("subject=") == issuer.lchop("issuer=")

      if self_signed
        puts "  #{VoIPAppz::Colors.dot_fail} #{VoIPAppz::Colors::LOCK}  #{label}:   #{VoIPAppz::Colors.dim("self-signed placeholder")}"
      else
        puts "  #{VoIPAppz::Colors.dot_ok} #{VoIPAppz::Colors::LOCK}  #{label}:   #{VoIPAppz::Colors.green("CA-issued")}"
        puts "     #{VoIPAppz::Colors.dim(issuer)}" unless issuer.empty?
      end
      puts "     #{VoIPAppz::Colors.dim(subject)}" unless subject.empty?
      puts "     #{VoIPAppz::Colors.dim(enddate)}" unless enddate.empty?
    end

    private def openssl_field(crt_path : String, field : String) : String
      io = IO::Memory.new
      Process.run("openssl", ["x509", "-noout", field, "-in", crt_path],
        output: io, error: Process::Redirect::Close)
      io.to_s.strip
    rescue
      ""
    end

    # --- issue / install ----------------------------------------------------

    private def issue_cert(domain : String, env : Hash(String, String))
      require_acmesh!
      dns = (env["VA_ACME_DNS"]? || "dns_cf").strip
      alias_zone = (env["VA_ACME_ALIAS"]? || "acme.voipappz.io").strip

      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::ROCKET} Issuing #{VoIPAppz::Colors.cyan(domain)} via #{dns} (challenge-alias #{alias_zone})...")
      cmd = ["acme.sh", "--issue", "--dns", dns, "-d", domain,
             "--challenge-alias", alias_zone, "--server", "letsencrypt"]
      # LE account email — expiry notices go here. Optional: acme.sh registers
      # an anonymous account when it is absent.
      email = (env["VA_SSL_EMAIL"]? || env["VA_ADMIN_EMAIL"]?).try(&.strip)
      if email && !email.empty?
        cmd << "--accountemail" << email
      end
      cmd << "--force" if flags.force

      # Not captured: acme.sh's progress (DNS propagation waits) is the useful
      # feedback during a 1-2 minute issuance.
      exit_code, _ = VoIPAppz::Docker.exec(ACME_CONTAINER, cmd, capture: false)

      # acme.sh exits 2 for "cert is still valid, skipping" — not a failure.
      if exit_code == 0
        puts VoIPAppz::Colors.success("Certificate issued")
      elsif exit_code == 2
        puts VoIPAppz::Colors.info("Certificate still valid — acme.sh skipped renewal (use --force to reissue)")
      else
        STDERR.puts VoIPAppz::Colors.error("acme.sh --issue failed (exit #{exit_code})")
        STDERR.puts "  Check: VA_CF_TOKEN scope (Zone:DNS:Edit) and the static CNAME"
        STDERR.puts "  _acme-challenge.#{domain} #{VoIPAppz::Colors::ARROW} _acme-challenge.#{alias_zone}"
        exit 1
      end
    end

    # Point acme.sh's installcert at the shared volume. server.* is the
    # canonical pair (Kong); the reloadcmd mirrors it to tls.* (kamailio) so
    # an unattended daemon renewal refreshes both — the CLI is not in that
    # loop. The reloadcmd cannot reload the services themselves: the acmesh
    # container has no docker socket. The daily ofelia `cert-reload` jobs on
    # kong and kamailio close that gap.
    private def install_cert(domain : String)
      require_acmesh!
      puts VoIPAppz::Colors.info("#{VoIPAppz::Colors::ARROW} Installing cert → certs/server.{crt,key} + certs/tls.{crt,key}")
      mirror = "cp #{OUT_DIR}/server.crt #{OUT_DIR}/tls.crt && cp #{OUT_DIR}/server.key #{OUT_DIR}/tls.key"
      exit_code, output = VoIPAppz::Docker.exec(ACME_CONTAINER, [
        "acme.sh", "--install-cert", "-d", domain,
        "--fullchain-file", "#{OUT_DIR}/server.crt",
        "--key-file", "#{OUT_DIR}/server.key",
        "--reloadcmd", mirror,
      ])
      if exit_code != 0
        STDERR.puts VoIPAppz::Colors.error("acme.sh --install-cert failed (exit #{exit_code})")
        STDERR.puts output unless output.empty?
        exit 1
      end
      puts "  #{VoIPAppz::Colors.dot_ok} wrote certs/server.* (Kong) and certs/tls.* (kamailio)"
    end

    private def require_acmesh!
      return if acmesh_running?
      STDERR.puts VoIPAppz::Colors.error("acmesh container is not running")
      STDERR.puts "  Start it: docker compose --profile app up -d acmesh"
      exit 1
    end

    # --- reload -------------------------------------------------------------

    # Both reloads are best-effort. Kong's is a zero-downtime nginx reload;
    # kamailio's only matters when tls.so is loaded (the current native cfg
    # terminates no TLS), so a failure there is informational — the files on
    # disk are the contract.
    private def reload_edge
      reload("kong", ["kong", "reload"], "Kong reloaded — new cert live on the HTTPS edge")
      reload("kamailio-egress", ["kamcmd", "tls.reload"], "egress tls.reload — new cert live")
    end

    private def reload(container : String, cmd : Array(String), ok_message : String)
      unless VoIPAppz::Docker.running_containers.includes?(container)
        puts "  #{VoIPAppz::Colors.dim("●")} #{container} not running — skipped"
        return
      end
      exit_code, output = VoIPAppz::Docker.exec(container, cmd)
      if exit_code == 0
        puts "  #{VoIPAppz::Colors.dot_ok} #{ok_message}"
      else
        detail = container.includes?("egress") ? "tls module not loaded — cert will be used when wss is enabled" : output.strip
        puts "  #{VoIPAppz::Colors.dim("●")} #{container} reload skipped (#{detail})"
      end
    end

    # --- .env ---------------------------------------------------------------

    private def load_env : Hash(String, String)
      env = {} of String => String
      path = File.join(VoIPAppz::Docker.project_dir, ".env")
      return env unless File.exists?(path)
      File.each_line(path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?("#")
        key, _, value = line.partition("=")
        next if value.empty? && !line.includes?("=")
        env[key.strip] = value.strip.strip('"')
      end
      env
    end
  end
end
