require "admiral"
require "http/client"
require "json"
require "socket"
require "../helpers/colors"
require "../helpers/net_validation"
require "../helpers/node_env"
require "../helpers/secrets"
require "../helpers/docker"
require "../helpers/wait"
require "../helpers/va_config"
require "../helpers/dispatcher_list"
require "../helpers/deploy_config"
require "../helpers/deploy_destination"
require "../helpers/table"
require "../helpers/topology"
require "../helpers/bao"
require "../helpers/bao_sync"

module VoIPAppz::Commands
  class Setup < Admiral::Command
    define_help description: "Configure environment and generate secrets"

    define_flag ci : Bool,
      description: "Non-interactive CI mode",
      default: false

    define_flag env_file : String,
      description: "Load a prepared answer file (KEY=VALUE) before setup — VOIPAPPZ_* wizard answers + VA_* vars — for unattended, env-driven install",
      default: ""

    def run
      project_dir = VoIPAppz::Docker.project_dir

      load_env_file(flags.env_file) unless flags.env_file.empty?

      if runtime_node_setup?
        run_runtime_node_setup(project_dir)
      elsif flags.ci
        run_ci_setup(project_dir)
      else
        run_interactive_setup(project_dir)
      end
    end

    # The production image has kamctl locally and mounts its one node document
    # at VA_PATH. VA_PATH alone is not enough: developers may set it while still
    # expecting the full host wizard. Both signals together mean this command is
    # running inside the SIP container and must touch only the mounted YAML.
    private def runtime_node_setup? : Bool
      path = ENV["VA_PATH"]?.try(&.strip)
      !!(path && !path.empty? && VoIPAppz::Docker.local_exec?)
    end

    private def run_runtime_node_setup(project_dir : String) : Nil
      path = VoIPAppz::VaConfig.yaml_path(project_dir)
      config = VoIPAppz::VaConfig.load(project_dir)
      detected_ip = detect_ip
      configured_external = config.nodes.first?.try(&.profile["ip_address_external"]?)
      node = VoIPAppz::VaConfig.prepare_runtime_node!(config, detected_ip)

      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::GEAR} Configure this node")
      puts VoIPAppz::Colors.dim("  Runtime mode: only #{path} will be written")
      puts ""

      if flags.ci
        internal_ip = detected_ip
        external_ip = if configured_external && VoIPAppz::NetValidation.usable_node_ipv4?(configured_external)
                        configured_external
                      else
                        detect_public_ip || internal_ip
                      end
      else
        node.name = prompt_valid("Node name", node.name,
          "must not be empty") { |value| !value.strip.empty? }.strip
        internal_ip = choose_internal_ip(detected_ip)
        current_external = node.profile["ip_address_external"]?
        external_default = if current_external && VoIPAppz::NetValidation.usable_node_ipv4?(current_external)
                             current_external
                           else
                             detect_public_ip || internal_ip
                           end
        external_ip = prompt_valid("External IP", external_default,
          "must be a non-loopback IPv4 address") { |value| VoIPAppz::NetValidation.usable_node_ipv4?(value) }
      end

      # prepare_node! owns identity and fixed ports; this call owns every
      # address, including all eight FreeSWITCH leg values.
      topology = VoIPAppz::VaConfig.configure_node_network!(
        config, internal_ip, external_ip, local_ips, replace_leg_ips: true)
      backup = VoIPAppz::VaConfig.write_yaml(config, project_dir)

      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} node configuration written")
      puts "  UUID:      #{node.uuid}"
      puts "  Name:      #{node.name}"
      puts "  Internal:  #{internal_ip}"
      puts "  External:  #{external_ip}"
      puts "  Topology:  #{topology_label(topology)}"
      if backup
        puts VoIPAppz::Colors.dim(
          "  temporary backup (container-local until restart) #{VoIPAppz::Colors::ARROW} #{backup}"
        )
      end
      puts VoIPAppz::Colors.info("Restart the node container to apply address or port changes.")
    end

    # Load a KEY=VALUE answer file into ENV so a prepared env file drives setup
    # end-to-end: VOIPAPPZ_* answers bypass every wizard prompt (see #prompt) and
    # VA_* vars feed VaConfig. The file is authoritative (it's the explicit answer
    # sheet) — edit the file, not the shell, to change a value. `installer.env.example`
    # is the committed template.
    private def load_env_file(path : String)
      unless File.exists?(path)
        STDERR.puts VoIPAppz::Colors.red("env file not found: #{path}")
        exit 1
      end
      count = 0
      File.each_line(path) do |raw|
        line = raw.strip
        next if line.empty? || line.starts_with?('#')
        line = line[7..].strip if line.starts_with?("export ")
        key, sep, val = line.partition('=')
        next if sep.empty?
        key = key.strip
        next if key.empty?
        val = val.strip
        if (val.starts_with?('"') && val.ends_with?('"')) || (val.starts_with?('\'') && val.ends_with?('\''))
          val = val[1...-1]
        end
        ENV[key] = val
        count += 1
      end
      puts VoIPAppz::Colors.dim("  loaded #{count} vars from #{path}")
    end

    private def run_ci_setup(project_dir : String)
      puts VoIPAppz::Colors.header("#{VoIPAppz::Colors::GEAR} CI Setup")
      puts ""

      # Load existing va.yaml or create default
      config = VoIPAppz::VaConfig.load(project_dir)

      # Auto-detect IP and resolve "auto" values
      ip = detect_ip
      VoIPAppz::VaConfig.prepare_node!(config, ip)

      # va.yaml may carry IPs from a previous host (cloned configs, image
      # baking, etc.). If they aren't bound on this machine they'll cause
      # services like Kamailio to fail with "Cannot assign requested address".
      # Heal them silently in CI mode — operator can override interactively.
      heal_stale_ips!(config, ip)

      # Populate granular per-leg IPs: external defaults to ifconfig.me when
      # reachable, otherwise falls back to the same internal IP (flat-LAN).
      first_node = config.nodes.first
      cur_ext = first_node.profile["ip_address_external"]?
      ext_for_legs = if cur_ext && !cur_ext.empty? && cur_ext != "auto"
                       cur_ext
                     else
                       (detect_public_ip || ip).tap { |v| first_node.profile["ip_address_external"] = v }
                     end
      topology = populate_leg_ips!(config, ip, ext_for_legs)
      VoIPAppz::VaConfig.validate_node_addresses!(config)
      puts VoIPAppz::Colors.success("Topology #{VoIPAppz::Colors::ARROW} #{topology_label(topology)}")

      # Generate secrets in memory
      secrets = VoIPAppz::SecretsHelper.generate_all_hash
      puts VoIPAppz::Colors.success("Secrets generated")

      # Write va.yaml (auto-backs up any existing one to *.bak.<ts>)
      yaml_backup = VoIPAppz::VaConfig.write_yaml(config, project_dir)
      puts VoIPAppz::Colors.success("config/va.yaml written")
      puts VoIPAppz::Colors.dim("  prior file backed up #{VoIPAppz::Colors::ARROW} #{yaml_backup}") if yaml_backup

      # Generate .env with secrets included (auto-backs up any existing .env)
      env_backup = VoIPAppz::VaConfig.write_env(config, project_dir, secrets)
      puts VoIPAppz::Colors.success(".env written (config + secrets)")
      puts VoIPAppz::Colors.dim("  prior file backed up #{VoIPAppz::Colors::ARROW} #{env_backup}") if env_backup

      write_dispatcher_list(config, project_dir)

      # Save the generated config+secrets to OpenBao (the source of truth) when
      # it's already up. On a fresh host Bao isn't running yet — the first
      # `voipappz up -p app` seeds it from these files instead.
      save_to_bao(project_dir)

      # Ensure directories + self-signed cert
      ensure_dirs(project_dir)
      puts VoIPAppz::Colors.success("Directories created")

      puts ""
      puts VoIPAppz::Colors.success("#{VoIPAppz::Colors::CHECK} CI setup completed")
    end

    private def run_interactive_setup(project_dir : String)
      total_steps = 7

      puts VoIPAppz::Colors.banner([
        "",
        "   #{VoIPAppz::Colors::ROCKET} VoIPAppz Setup Wizard",
        "",
        "   Identity, network and TLS for THIS node.",
        "   config/va.yaml + .env are written at the end.",
        "   Press Enter to accept [default] values.",
        "",
      ])
      puts ""

      # Alert channels are NOT asked for — they are node-agnostic and belong to
      # the answer sheet / an existing .env. Carried forward so a re-run never
      # blanks SMTP_*/VA_ALERT_SLACK_WEBHOOK (to_env defaults them to "").
      alert_secrets = carried_alert_channels
      # TLS / acme.sh answers (filled by step 3; consumed by the write step).
      tls_secrets = {} of String => String

      # Load existing va.yaml if present (preserves license, deploy, etc.)
      config = VoIPAppz::VaConfig.load(project_dir)
      org = config.organization

      # Step 1: Organization
      print_step_header(1, total_steps, "Organization #{VoIPAppz::Colors::GEAR}")
      org.name = prompt("Organization name", org.name)
      # The domain is load-bearing: it becomes VA_DOMAIN, the SIP domain phones
      # register against, and the name acme.sh issues the certificate for.
      org.domain = prompt_valid("Domain", org.domain,
        "not a valid domain name") { |v| VoIPAppz::NetValidation.valid_hostname?(v) }
      org.email = prompt_valid("Admin email",
        org.email == "admin@voipappz.local" ? "admin@#{org.domain}" : org.email,
        "not a valid email address") { |v| VoIPAppz::NetValidation.valid_email?(v) }
      puts ""

      # Step 2: Network
      detected_ip = detect_ip
      print_step_header(2, total_steps, "Network #{VoIPAppz::Colors::NET}")

      # Resolve external IP from two independent sources so the operator can
      # cross-check that DNS matches what the box actually egresses as.
      resolved_ip = resolve_domain_ip(org.domain)
      public_ip = detect_public_ip

      if resolved_ip
        puts VoIPAppz::Colors.success("DNS  #{VoIPAppz::Colors.cyan(org.domain)} #{VoIPAppz::Colors::ARROW} #{VoIPAppz::Colors.cyan(resolved_ip)}")
      else
        puts VoIPAppz::Colors.warning("DNS  #{VoIPAppz::Colors.cyan(org.domain)} did not resolve")
      end
      if public_ip
        puts VoIPAppz::Colors.success("WAN  ifconfig.me #{VoIPAppz::Colors::ARROW} #{VoIPAppz::Colors.cyan(public_ip)}")
      else
        puts VoIPAppz::Colors.warning("WAN  ifconfig.me lookup failed (no internet?)")
      end
      if resolved_ip && public_ip && resolved_ip != public_ip
        puts VoIPAppz::Colors.warning(
          "Mismatch: DNS=#{resolved_ip} ≠ WAN=#{public_ip}. Domain may point elsewhere; verify before proceeding."
        )
      end

      VoIPAppz::VaConfig.prepare_node!(config, detected_ip)
      n = config.nodes.first
      cur_ext = n.profile["ip_address_external"]?

      # External IP default priority: DNS-resolved → public WAN → existing config → detected internal
      ext_default = resolved_ip || public_ip ||
                    ((cur_ext.nil? || cur_ext == "auto") ? detected_ip : cur_ext)
      external_ip = prompt_valid("External IP", ext_default,
        "must be a non-loopback IPv4 address") { |value| VoIPAppz::NetValidation.usable_node_ipv4?(value) }
      n.profile["ip_address_external"] = external_ip

      # Internal IP: show available interfaces as numbered choices
      internal_ip = choose_internal_ip(detected_ip)
      n.profile["ip_address_internal"] = internal_ip
      n.profile["eventsocket_address"] = internal_ip
      # Catch any stale IPs in other nodes / sip_interfaces inherited from a
      # prior va.yaml so the operator doesn't ship a config that won't bind.
      heal_stale_ips!(config, internal_ip)

      # Populate the eight granular per-leg IPs on each sip_interface so the
      # kamailio sync and FS sofia config can pick the right bind/advertised
      # addr per leg without further prompting. Operator overrides preserved.
      topology = populate_leg_ips!(config, internal_ip, external_ip)
      puts VoIPAppz::Colors.success(
        "Topology #{VoIPAppz::Colors::ARROW} #{VoIPAppz::Colors.cyan(topology_label(topology))}"
      )
      puts ""

      # Step 3: TLS certificates
      print_step_header(3, total_steps, "TLS Certificates #{VoIPAppz::Colors::LOCK}")
      collect_tls(tls_secrets, org.domain)
      puts ""

      # Step 4: Environment
      print_step_header(4, total_steps, "Environment #{VoIPAppz::Colors::BOLT}")
      org.environment = prompt("Environment", org.environment)
      puts ""

      # Step 5: Review
      print_step_header(5, total_steps, "Review")
      puts VoIPAppz::Colors.divider
      puts VoIPAppz::Colors.bold("  Review your configuration:")
      puts ""
      puts "    Organization:  #{VoIPAppz::Colors.cyan(org.name)}"
      puts "    Domain:        #{VoIPAppz::Colors.cyan(org.domain)}"
      puts "    Admin email:   #{VoIPAppz::Colors.cyan(org.email)}"
      # Read the addresses back off the node, not off the answers: heal_stale_ips!
      # may have rewritten one that isn't bound here, and the review has to show
      # what will be written — otherwise it confirms a value the summary then
      # contradicts.
      puts "    External IP:   #{VoIPAppz::Colors.cyan(n.profile["ip_address_external"]? || external_ip)}"
      puts "    Internal IP:   #{VoIPAppz::Colors.cyan(n.profile["ip_address_internal"]? || internal_ip)}"
      puts "    Environment:   #{VoIPAppz::Colors.cyan(org.environment)}"
      enabled = enabled_alert_channels(alert_secrets)
      puts "    Alerts:        #{VoIPAppz::Colors.cyan(enabled.empty? ? "(none — silent monitoring)" : enabled.join(", "))}"
      puts "    TLS:           #{VoIPAppz::Colors.cyan(tls_summary(tls_secrets))}"
      puts ""
      puts VoIPAppz::Colors.divider
      confirm = prompt("Proceed with setup?", "yes")
      unless confirm.downcase.starts_with?("y")
        puts VoIPAppz::Colors.warning("Setup cancelled.")
        exit 0
      end
      puts ""

      # Step 6: Generate secrets
      print_step_header(6, total_steps, "Generating Secrets #{VoIPAppz::Colors::KEY}")
      secrets = VoIPAppz::SecretsHelper.generate_all_hash
      alert_secrets.each { |k, v| secrets[k] = v }
      tls_secrets.each { |k, v| secrets[k] = v }

      # Resolve node identity and the fixed SIP port layout.
      VoIPAppz::VaConfig.prepare_node!(config, internal_ip)
      VoIPAppz::VaConfig.validate_node_addresses!(config)

      puts VoIPAppz::Colors.success("Secrets generated")
      puts ""

      # Step 7: Write files (auto-backs up any prior va.yaml / .env)
      print_step_header(7, total_steps, "Writing Files #{VoIPAppz::Colors::SHIELD}")
      yaml_backup = VoIPAppz::VaConfig.write_yaml(config, project_dir)
      puts VoIPAppz::Colors.success("config/va.yaml written")
      puts VoIPAppz::Colors.dim("  prior file backed up #{VoIPAppz::Colors::ARROW} #{yaml_backup}") if yaml_backup
      env_backup = VoIPAppz::VaConfig.write_env(config, project_dir, secrets)
      puts VoIPAppz::Colors.success(".env generated (config + secrets)")
      puts VoIPAppz::Colors.dim("  prior file backed up #{VoIPAppz::Colors::ARROW} #{env_backup}") if env_backup

      write_dispatcher_list(config, project_dir)

      # Save the generated config+secrets to OpenBao (the source of truth) when
      # it's already up; a fresh host's first `voipappz up` seeds it instead.
      save_to_bao(project_dir)

      ensure_dirs(project_dir)
      puts VoIPAppz::Colors.success("Directories and certificates ready")
      puts ""

      print_final_summary(config, org, topology, tls_secrets, alert_secrets, secrets)
    end

    # The end-of-run summary: what this node was actually configured as. The
    # network block is the part worth reading — the per-leg bind/advertise
    # addresses are derived, not asked for, so this is the only place an
    # operator gets to see what they came out as before `voipappz up` binds
    # them. (Setup never touches the host's own networking — no netplan, no
    # interfaces; it only records which addresses the stack should use.)
    private def print_final_summary(config : DeployConfig,
                                    org : OrganizationConfig,
                                    topology : Symbol,
                                    tls_secrets : Hash(String, String),
                                    alert_secrets : Hash(String, String),
                                    secrets : Hash(String, String))
      n = config.nodes.first
      si = config.sip_interfaces.first?
      ready = VoIPAppz::SecretsHelper::SECRETS.keys.count { |k| (v = secrets[k]?) && !v.empty? }

      puts VoIPAppz::Colors.divider
      puts VoIPAppz::Colors.bold("  #{VoIPAppz::Colors::CHECK} Setup complete — this node")
      puts ""
      puts "    Organization:  #{VoIPAppz::Colors.cyan(org.name)}"
      puts "    Domain:        #{VoIPAppz::Colors.cyan(org.domain)}  #{VoIPAppz::Colors.dim("(SIP domain + TLS name)")}"
      puts "    Environment:   #{VoIPAppz::Colors.cyan(org.environment)}"
      puts "    Node UUID:     #{VoIPAppz::Colors.dim(n.uuid)}"
      puts ""
      puts VoIPAppz::Colors.bold("  Network #{VoIPAppz::Colors::NET}")
      puts "    Topology:      #{VoIPAppz::Colors.cyan(topology_label(topology))}"
      puts "    Internal IP:   #{VoIPAppz::Colors.cyan(n.profile["ip_address_internal"]? || "—")}  #{VoIPAppz::Colors.dim("(bind — kamailio, event socket, DB)")}"
      puts "    External IP:   #{VoIPAppz::Colors.cyan(n.profile["ip_address_external"]? || "—")}  #{VoIPAppz::Colors.dim("(advertised to carriers/phones)")}"
      if si
        puts VoIPAppz::Colors.dim("    SIP legs (#{si.name}) — bind #{VoIPAppz::Colors::ARROW} advertised:")
        {
          "phones  SIP" => {"ip_address_internal_int_sip", "ip_address_internal_ext_sip"},
          "phones  RTP" => {"ip_address_internal_int_rtp", "ip_address_internal_ext_rtp"},
          "carrier SIP" => {"ip_address_external_int_sip", "ip_address_external_ext_sip"},
          "carrier RTP" => {"ip_address_external_int_rtp", "ip_address_external_ext_rtp"},
        }.each do |label, (bind_key, adv_key)|
          bind = si.profile[bind_key]? || "—"
          adv = si.profile[adv_key]? || "—"
          puts "      #{label}:  #{VoIPAppz::Colors.cyan(bind)} #{VoIPAppz::Colors::ARROW} #{VoIPAppz::Colors.cyan(adv)}"
        end
      end
      puts ""
      puts VoIPAppz::Colors.bold("  Services")
      puts "    TLS:           #{VoIPAppz::Colors.cyan(tls_summary(tls_secrets))}"
      alerts = enabled_alert_channels(alert_secrets)
      puts "    Alerts:        #{VoIPAppz::Colors.cyan(alerts.empty? ? "none" : alerts.join(", "))}  #{VoIPAppz::Colors.dim("(set SMTP_*/VA_ALERT_SLACK_WEBHOOK in .env)")}"
      puts "    Secrets:       #{VoIPAppz::Colors.cyan("#{ready}/#{VoIPAppz::SecretsHelper::SECRETS.size} generated")}"
      puts ""
      puts VoIPAppz::Colors.bold("  Files")
      puts "    #{VoIPAppz::Colors.dim("config/va.yaml")}  node identity and SIP interfaces"
      puts "    #{VoIPAppz::Colors.dim(".env")}            config + secrets (0600)"
      puts ""
      puts VoIPAppz::Colors.bold("  Next")
      puts "    #{VoIPAppz::Colors::ARROW} voipappz up        Start services"
      puts "    #{VoIPAppz::Colors::ARROW} voipappz health    Check service health"
      puts "    #{VoIPAppz::Colors::ARROW} voipappz cert      Verify the certificate is not the placeholder"
      puts VoIPAppz::Colors.divider
      puts ""
    end

    private def print_step_header(step : Int32, total : Int32, title : String)
      puts "  #{VoIPAppz::Colors.progress_bar(step, total)}  #{VoIPAppz::Colors.bold(title)}"
    end

    # Build the VA_* env hash from config (for vault storage compatibility)
    # The INGRESS kamailio has no database — its destinations are a plain text
    # file, derived from va.yaml. Written HERE, at init, for the same reason
    # .env is: the file has to exist before `voipappz up`, because compose
    # bind-mounts it and docker turns a missing bind-mount source into an empty
    # DIRECTORY mounted over the path, which kamailio then cannot read.
    #
    # An empty list is fail-closed on purpose: the ingress 404s every call
    # rather than black-holing it, so an unseeded node is loud. `voipappz sbc ingress
    # sync` rewrites this file and reloads it live.
    private def write_dispatcher_list(config : DeployConfig, project_dir : String) : Nil
      rows = VoIPAppz::DispatcherList.entries(config)
      path = VoIPAppz::DispatcherList.write(rows, project_dir)
      if rows.empty?
        puts VoIPAppz::Colors.success("#{VoIPAppz::DispatcherList::HOST_PATH} written (empty)")
        puts VoIPAppz::Colors.dim("  no nodes with role=switch yet — the ingress fails closed (404) until `voipappz sbc ingress sync`")
      else
        puts VoIPAppz::Colors.success("#{VoIPAppz::DispatcherList::HOST_PATH} written (#{rows.size} destination(s))")
      end
    end

    private def auto_detect_config_hash(config : DeployConfig) : Hash(String, String)
      VoIPAppz::VaConfig.to_env(config)
    end

    # Pick the first non-loopback, non-docker interface IP. `hostname -I`
    # output order is unreliable (we've seen stale leases come first), and
    # docker bridges (docker0, br-*) are useless for service binding even
    # if hostname -I includes them. Setup stops when the host has no physical
    # address: a loopback fallback would create a node that looks healthy only
    # from inside itself.
    private def detect_ip : String
      ips = list_interface_ips
      if first = ips.first?
        first[:ip]
      else
        STDERR.puts VoIPAppz::Colors.error("No non-loopback IPv4 address detected; configure a network interface before setup")
        exit 1
      end
    end

    # Resolve domain name to IP address via DNS
    private def resolve_domain_ip(domain : String) : String?
      return nil if domain.empty? || domain == "voipappz.local" || domain.ends_with?(".local")

      # Try getent first (most portable)
      stdout = IO::Memory.new
      process = Process.new("getent", ["ahosts", domain], output: stdout, error: Process::Redirect::Close)
      if process.wait.success?
        # First line: "1.2.3.4  STREAM domain"
        first_line = stdout.to_s.strip.split("\n").first?
        if first_line
          ip = first_line.split.first?
          return ip if ip && ip =~ /^\d+\.\d+\.\d+\.\d+$/
        end
      end

      # Fallback: dig
      stdout = IO::Memory.new
      process = Process.new("dig", ["+short", domain, "A"], output: stdout, error: Process::Redirect::Close)
      if process.wait.success?
        ip = stdout.to_s.strip.split("\n").first?
        return ip if ip && ip =~ /^\d+\.\d+\.\d+\.\d+$/
      end

      nil
    rescue
      nil
    end

    # Discover this host's public/WAN IP by asking an external service.
    # Tries ifconfig.me first, then api.ipify.org as fallback. Each call is
    # capped at 3s so a slow/blocked egress doesn't stall the wizard.
    private def detect_public_ip : String?
      ["https://ifconfig.me/ip", "https://api.ipify.org"].each do |url|
        stdout = IO::Memory.new
        process = Process.new(
          "curl",
          ["-sS", "--max-time", "3", "-fL", url],
          output: stdout,
          error: Process::Redirect::Close,
        )
        if process.wait.success?
          ip = stdout.to_s.strip
          return ip if ip =~ /^\d+\.\d+\.\d+\.\d+$/
        end
      end
      nil
    rescue
      nil
    end

    # List available network interface IPs and let user choose
    private def choose_internal_ip(detected_ip : String) : String
      ips = list_interface_ips
      if ips.size <= 1
        return prompt_valid("Internal IP", detected_ip,
          "must be a non-loopback IPv4 address") { |value| VoIPAppz::NetValidation.usable_node_ipv4?(value) }
      end

      puts ""
      puts VoIPAppz::Colors.info("Available network interfaces:")
      ips.each_with_index do |entry, idx|
        marker = entry[:ip] == detected_ip ? " #{VoIPAppz::Colors.green("(detected)")}" : ""
        puts "    #{VoIPAppz::Colors.cyan((idx + 1).to_s)}. #{entry[:ip]}  #{VoIPAppz::Colors.dim(entry[:iface])}#{marker}"
      end
      puts "    #{VoIPAppz::Colors.cyan((ips.size + 1).to_s)}. Custom"
      puts ""

      default_idx = ips.index { |e| e[:ip] == detected_ip }
      default_num = default_idx ? (default_idx + 1).to_s : "1"

      choice = prompt("Choose internal IP", default_num)

      num = choice.to_i? || 0
      if num >= 1 && num <= ips.size
        selected = ips[num - 1][:ip]
        puts VoIPAppz::Colors.success("Selected: #{VoIPAppz::Colors.cyan(selected)}")
        selected
      elsif num == ips.size + 1
        prompt_valid("Enter custom IP", detected_ip,
          "must be a non-loopback IPv4 address") { |value| VoIPAppz::NetValidation.usable_node_ipv4?(value) }
      else
        # Treat as direct IP input if it looks like an IP
        if VoIPAppz::NetValidation.usable_node_ipv4?(choice)
          choice
        else
          prompt_valid("Enter custom IP", detected_ip,
            "must be a non-loopback IPv4 address") { |value| VoIPAppz::NetValidation.usable_node_ipv4?(value) }
        end
      end
    end

    # Get list of network interface IPs
    private def list_interface_ips : Array(NamedTuple(iface: String, ip: String))
      result = [] of NamedTuple(iface: String, ip: String)
      stdout = IO::Memory.new
      process = Process.new("ip", ["-4", "-o", "addr", "show"], output: stdout, error: Process::Redirect::Close)
      return result unless process.wait.success?

      stdout.to_s.strip.split("\n").each do |line|
        # Format: "2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0"
        parts = line.split
        next if parts.size < 4
        iface = parts[1].rstrip(':')
        next if iface == "lo"
        # Filter docker-managed bridges — they're never the right bind target
        # for SIP/HTTP and just clutter the menu.
        next if iface == "docker0"
        next if iface.starts_with?("br-")
        next if iface.starts_with?("veth")
        ip_cidr = parts[3]
        ip = ip_cidr.split("/").first
        next unless ip =~ /^\d+\.\d+\.\d+\.\d+$/
        result << {iface: iface, ip: ip}
      end

      result
    rescue
      [] of NamedTuple(iface: String, ip: String)
    end

    # Set of every IPv4 currently bound on a non-loopback, non-docker
    # interface. Used to validate that a config-supplied IP actually
    # belongs to this host before we let services try to bind to it.
    private def local_ips : Set(String)
      ips = Set(String).new
      list_interface_ips.each { |entry| ips << entry[:ip] }
      ips
    end

    # If a node or sip_interface in the loaded config refers to an IP that
    # isn't on this host (typical for cloned va.yaml or image-baked setups),
    # rewrite it to the detected IP. Internal-only — bind-target IPs.
    # External IPs are left alone since they may legitimately be a NAT/EIP
    # not bound on the box (we just warn).
    private def heal_stale_ips!(config : DeployConfig, detected : String) : Nil
      bound = local_ips
      changed = false

      config.nodes.each do |n|
        ["ip_address_internal", "eventsocket_address"].each do |key|
          val = n.profile[key]?
          next if val.nil? || val.empty? || val == "auto"
          unless bound.includes?(val)
            puts VoIPAppz::Colors.warning(
              "Healing stale #{key}=#{val} → #{detected} (not bound on this host)"
            )
            n.profile[key] = detected
            changed = true
          end
        end
      end

      config.sip_interfaces.each do |si|
        val = si.profile["ip_address_internal"]?
        next if val.nil? || val.empty? || val == "auto"
        unless bound.includes?(val)
          puts VoIPAppz::Colors.warning(
            "Healing stale sip_interface internal IP=#{val} → #{detected}"
          )
          si.profile["ip_address_internal"] = detected
          changed = true
        end
      end

      # External (advertise) addresses: a NAT/EIP legitimately isn't bound on
      # the box, so the test is against this host's DETECTED public IP, not
      # the bound list. An external that is neither bound, nor detected, nor
      # this host's public IP is a leftover from another machine (cloned
      # va.yaml, image baking, an example file) — advertising it poisons
      # FreeSWITCH's PUBLIC_IP_ADDR, every SDP, and the sofia profiles, which
      # surfaces as unexplainable SIP failures long after setup. Heal it to
      # the detected public IP (or the internal IP on a flat LAN).
      public_ip = detect_public_ip
      healthy_ext = ->(v : String) {
        bound.includes?(v) || v == detected || (public_ip && v == public_ip)
      }
      ext_target = public_ip || detected
      config.nodes.each do |n|
        val = n.profile["ip_address_external"]?
        next if val.nil? || val.empty? || val == "auto"
        next if healthy_ext.call(val)
        puts VoIPAppz::Colors.warning(
          "Healing stale ip_address_external=#{val} → #{ext_target} (not this host's address)"
        )
        n.profile["ip_address_external"] = ext_target
        changed = true
      end
      config.sip_interfaces.each do |si|
        si.profile.keys.select { |k| k.starts_with?("ip_address_external") }.each do |key|
          val = si.profile[key]
          next if val.empty? || val == "auto"
          next if healthy_ext.call(val)
          puts VoIPAppz::Colors.warning(
            "Healing stale #{key}=#{val} → #{ext_target} (not this host's address)"
          )
          si.profile[key] = ext_target
          changed = true
        end
      end

      if changed
        puts VoIPAppz::Colors.dim("  Note: external IPs left untouched (may be a public/NAT address).")
      end
    end

    # A prompt's answer can be supplied up-front as VOIPAPPZ_<LABEL>, which is
    # what --env-file exists for: an unattended interactive run. Derived from
    # the label so the answer sheet stays readable ("SMTP host" ->
    # VOIPAPPZ_SMTP_HOST). Without this the wizard blocks on stdin forever in
    # any non-tty context, which is how a piped `curl | sh` install hangs.
    # `key` pins the answer name when the label is dynamic (e.g. the Cloudflare
    # prompt embeds the alias zone) — otherwise the answer sheet would have to
    # change every time the label text does.
    private def answer_key(label : String, key : String? = nil) : String
      return "VOIPAPPZ_#{key}" if key
      "VOIPAPPZ_" + label.strip.upcase.gsub(/[^A-Z0-9]+/, "_").strip('_')
    end

    private def prompt(label : String, default : String, key : String? = nil) : String
      if preset = ENV[answer_key(label, key)]?
        puts "  #{VoIPAppz::Colors::ARROW} #{label}: #{VoIPAppz::Colors.cyan(preset)} #{VoIPAppz::Colors.dim("(#{answer_key(label, key)})")}"
        return preset
      end
      print "  #{VoIPAppz::Colors::ARROW} #{label} [#{VoIPAppz::Colors.cyan(default)}]: "
      input = gets
      value = input ? input.strip : ""
      value.empty? ? default : value
    end

    # Re-prompt until the answer validates. A preset (VOIPAPPZ_*) or a
    # non-tty stdin must NOT spin forever, so both fall through after one
    # rejection with a warning — an unattended run reports the bad value
    # instead of hanging.
    private def prompt_valid(label : String, default : String, hint : String, & : String -> Bool) : String
      3.times do
        value = prompt(label, default)
        return value if yield value
        puts VoIPAppz::Colors.warning("  #{hint} (got: #{value.empty? ? "empty" : value})")
        if ENV[answer_key(label)]? || !STDIN.tty?
          puts VoIPAppz::Colors.dim("  non-interactive — keeping it; fix in .env before going live")
          return value
        end
      end
      puts VoIPAppz::Colors.warning("  giving up after 3 tries — using #{default.empty? ? "empty" : default}")
      default
    end

    private def yes_no?(label : String, default : Bool) : Bool
      if preset = ENV[answer_key(label)]?
        val = preset.strip.downcase.starts_with?("y") || preset.strip.downcase == "true"
        puts "  #{VoIPAppz::Colors::ARROW} #{label}: #{VoIPAppz::Colors.cyan(val ? "yes" : "no")} #{VoIPAppz::Colors.dim("(#{answer_key(label)})")}"
        return val
      end
      default_str = default ? "Y/n" : "y/N"
      print "  #{VoIPAppz::Colors::ARROW} #{label} [#{VoIPAppz::Colors.cyan(default_str)}]: "
      input = gets
      value = input ? input.strip.downcase : ""
      return default if value.empty?
      value.starts_with?("y")
    end

    # Step 4: TLS. acme.sh (DNS-01) is the only cert authority in the stack —
    # Kong merely serves certs/server.*. DNS-01 is what lets the DC firewall
    # stay closed, but it needs a Cloudflare token for OUR delegated zone, and
    # nothing else in the wizard collects it. Skipping this leaves the node on
    # the self-signed placeholder — TLS still negotiates, so the failure is
    # silent until a browser rejects the cert.
    private def collect_tls(tls_secrets : Hash(String, String), domain : String)
      puts VoIPAppz::Colors.info("Certificates are issued by acme.sh over DNS-01 (no open port 80 needed).")

      if domain.empty? || domain.ends_with?(".local")
        puts VoIPAppz::Colors.warning("No public domain set — keeping the self-signed certificate.")
        puts VoIPAppz::Colors.dim("  Re-run setup with a real domain, then: voipappz cert --issue")
        return
      end

      unless yes_no?("Configure Let's Encrypt now?", true)
        puts VoIPAppz::Colors.warning("Skipped — running on the self-signed certificate.")
        puts VoIPAppz::Colors.dim("  Configure later: set VA_CF_TOKEN in .env, then voipappz cert --issue")
        return
      end

      alias_zone = prompt("Cloudflare-managed challenge zone", env_or("VA_ACME_ALIAS", "acme.voipappz.io"), key: "ACME_ALIAS").strip
      if alias_zone.downcase == domain.strip.downcase
        puts VoIPAppz::Colors.warning("The challenge-alias zone must be different from the customer domain.")
        puts VoIPAppz::Colors.dim("  Use a zone controlled by VoIPAppz, such as acme.voipappz.io.")
        alias_zone = prompt("Cloudflare-managed challenge zone", "acme.voipappz.io", key: "ACME_ALIAS").strip
      end
      if alias_zone.empty? || alias_zone.downcase == domain.strip.downcase
        puts VoIPAppz::Colors.warning("Invalid challenge-alias zone — keeping the self-signed certificate.")
        return
      end

      token = prompt("Cloudflare API token (Zone:DNS:Edit on #{alias_zone})", env_or("VA_CF_TOKEN"), key: "CF_TOKEN")
      token = token.strip
      if token.empty?
        puts VoIPAppz::Colors.warning("No token given — acme.sh cannot issue; keeping the self-signed cert.")
        return
      end

      # Cloudflare tokens are opaque and their exact format may evolve. Keep
      # this deliberately broad: reject obvious input mistakes locally, then
      # let Cloudflare's verification endpoint validate scope and revocation.
      if token.size < 20 || token.size > 256 || token =~ /\s/
        puts VoIPAppz::Colors.warning("Cloudflare token must be 20–256 characters with no whitespace.")
        return
      end

      verify_cf_token(token)

      puts ""
      puts VoIPAppz::Colors.bold("  DNS delegation required before certificate issuance:")
      puts "    #{VoIPAppz::Colors.cyan("_acme-challenge.#{domain}")}  CNAME  #{VoIPAppz::Colors.cyan("_acme-challenge.#{alias_zone}")}"
      puts VoIPAppz::Colors.dim("  Add this record to the customer domain, then run: voipappz cert --issue")
      puts ""

      tls_secrets["acme_cf_token"] = token
      tls_secrets["acme_alias"] = alias_zone.strip
      tls_secrets["acme_dns"] = env_or("VA_ACME_DNS", "dns_cf")
      puts VoIPAppz::Colors.success("acme.sh configured — issue after boot with: voipappz cert --issue")
    end

    # Ask Cloudflare whether the token is live before writing it to .env.
    # A revoked/typo'd/wrong-scope token is otherwise indistinguishable from a
    # correct one until acme.sh fails at issuance time, on a host the operator
    # has already walked away from. Advisory only — no network, no verdict.
    private def verify_cf_token(token : String)
      print "  #{VoIPAppz::Colors::ARROW} verifying token with Cloudflare ... "
      client = HTTP::Client.new("api.cloudflare.com", tls: true)
      client.connect_timeout = 5.seconds
      client.read_timeout = 5.seconds
      response = client.get("/client/v4/user/tokens/verify",
        headers: HTTP::Headers{"Authorization" => "Bearer #{token}"})
      client.close

      if response.status_code == 200 && (JSON.parse(response.body)["success"]?.try(&.as_bool?) == true)
        puts VoIPAppz::Colors.green("valid + active")
      elsif response.status_code == 401 || response.status_code == 403
        puts VoIPAppz::Colors.red("rejected (HTTP #{response.status_code})")
        puts VoIPAppz::Colors.dim("     token is invalid, expired, or revoked — acme.sh will not be able to issue")
      else
        puts VoIPAppz::Colors.warning("inconclusive (HTTP #{response.status_code})")
      end
    rescue ex
      puts VoIPAppz::Colors.warning("could not reach Cloudflare (#{ex.message}) — storing unverified")
    end

    private def tls_summary(tls_secrets : Hash(String, String)) : String
      if tls_secrets["acme_cf_token"]?
        "Let's Encrypt via acme.sh (DNS-01, alias #{tls_secrets["acme_alias"]?})"
      else
        "self-signed (no ACME token configured)"
      end
    end

    # Alert channels (SMTP + Slack) are not wizard questions: they are the same
    # for every node an operator runs, and asking six SMTP fields per install is
    # what made setup feel unrelated to bringing a node up. They come from the
    # environment instead — an existing .env (loaded at startup) or the
    # --env-file answer sheet. Carrying them forward matters because to_env
    # defaults these keys to "", so a re-run would otherwise blank working
    # alerting. Set them in .env and re-run, or edit .env directly.
    private def carried_alert_channels : Hash(String, String)
      carried = {} of String => String
      {
        "alert_smtp_host"     => "SMTP_HOST",
        "alert_smtp_port"     => "SMTP_PORT",
        "alert_smtp_username" => "SMTP_USERNAME",
        "alert_smtp_password" => "SMTP_PASSWORD",
        "alert_smtp_from"     => "SMTP_FROM",
        "alert_email_to"      => "ALERT_EMAIL_TO",
        "alert_slack_webhook" => "VA_ALERT_SLACK_WEBHOOK",
      }.each do |secret_key, env_key|
        val = env_or(env_key)
        carried[secret_key] = val unless val.empty?
      end
      carried
    end

    # Like ENV.fetch, but treats an empty-string env value as missing.
    # The .env writer initializes alert keys to "" when nothing's set, so a
    # plain ENV.fetch would return "" instead of the caller's fallback.
    private def env_or(key : String, fallback : String = "") : String
      val = ENV[key]?
      (val.nil? || val.empty?) ? fallback : val
    end

    private def enabled_alert_channels(alert_secrets : Hash(String, String)) : Array(String)
      out = [] of String
      out << "Email" if alert_secrets["alert_email_to"]?
      out << "Slack" if alert_secrets["alert_slack_webhook"]?
      out
    end

    # Thin wrapper around VoIPAppz::Topology.populate! — passes this host's
    # actual NIC IPs so detection reflects reality. The pure topology logic
    # lives in helpers/topology.cr and is unit-tested in spec/topology_spec.cr.
    private def populate_leg_ips!(config : DeployConfig, internal_ip : String, external_ip : String) : Symbol
      VoIPAppz::Topology.populate!(config, internal_ip, external_ip, local_ips)
    end

    private def topology_label(t : Symbol) : String
      VoIPAppz::Topology.label(t)
    end

    # Push the freshly generated config+secrets into OpenBao when it's already
    # unsealed, making Bao the source of truth. No-op (with a hint) when Bao
    # isn't up yet — a fresh host's first `voipappz up -p app` seeds it from the
    # files we just wrote. Never fails setup.
    private def save_to_bao(project_dir : String)
      st = VoIPAppz::Bao.status
      unless st.running && !st.sealed
        puts VoIPAppz::Colors.dim("  OpenBao not up yet — 'voipappz up -p app' will seed it from these files")
        return
      end
      VoIPAppz::Bao.enable_kv
      res = VoIPAppz::BaoSync.push(project_dir)
      puts VoIPAppz::Colors.success("OpenBao saved (#{res.keys} keys, #{res.files.size} files) — source of truth")
    rescue ex
      puts VoIPAppz::Colors.warning("  OpenBao save skipped: #{ex.message}")
    end

    private def ensure_dirs(project_dir : String)
      dirs = [
        "certs",
        "config",
        "switch/recordings",
        "switch/copied",
      ]
      dirs.each do |dir|
        path = File.join(project_dir, dir)
        Dir.mkdir_p(path) unless Dir.exists?(path)
      end

      # NOTE: no certificate generation here. The CLI is deliberately out of
      # the SSL business — acme.sh owns issuance, and each TLS terminator
      # generates its own self-signed placeholder at boot (see the `openssl
      # req` blocks in the kamailio and kong entrypoints in
      # docker-compose.yaml). That keeps the placeholder with the container
      # that needs it, so it works even when a host skipped `voipappz setup`,
      # and removes openssl as a host dependency of the wizard.
    end
  end
end
