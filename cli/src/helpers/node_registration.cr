require "http/client"
require "json"
require "uri"
require "openssl"
require "socket"
require "./deploy_config"
require "./net_validation"
require "./node_env"

module VoIPAppz::NodeRegistration
  extend self

  UUID_V4_RE = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\z/

  class Error < Exception
  end

  enum Operation
    Created
    Existing
    Updated
  end

  record Result,
    operation : Operation,
    node_uuid : String

  # Authorization is an argument, never part of DeployConfig, so it cannot be
  # serialized into the node file by this path.
  def register(config_path : String, authorization_header : String) : Result
    @@config_dir = File.dirname(File.expand_path(config_path))
    authorization = validate_authorization(authorization_header)
    raise Error.new("node config not found: #{config_path}") unless File.exists?(config_path)

    config = DeployConfig.load(config_path)
    if key = NodeEnv::PROCESS_ONLY_ENV_KEYS.find { |candidate| config.env.has_key?(candidate) }
      raise Error.new("va.yaml must not contain #{key}; pass it in the command environment")
    end
    unless config.nodes.size == 1
      raise Error.new("va.yaml must contain exactly one node to register")
    end
    node = config.nodes.first
    validate_node!(node)

    response, operation = create_unless_present(api_root(config.mothership.url), node, authorization)
    validate_response_uuid!(response.body, node.uuid)
    Result.new(operation, node.uuid)
  rescue ex : Error
    raise ex
  rescue ex : YAML::ParseException
    raise Error.new("invalid va.yaml: #{ex.message}")
  rescue ex
    raise Error.new(redact(ex.message.to_s, authorization_header))
  end

  private def validate_authorization(raw : String) : String
    authorization = raw.strip
    scheme, separator, credentials = authorization.partition(' ')
    unless scheme == "Basic" && !separator.empty? && !credentials.strip.empty? &&
           !authorization.includes?('\n') && !authorization.includes?('\r')
      raise Error.new("VA_API_AUTHORIZATION must contain a Basic authorization value")
    end
    authorization
  end

  private def validate_node!(node : NodeConfig) : Nil
    unless UUID_V4_RE.matches?(node.uuid)
      raise Error.new("va.yaml node uuid is missing or is not UUID v4")
    end
    raise Error.new("va.yaml node name is missing") if node.name.strip.empty?
    unless node.type == "switch" && node.roles.includes?("switch")
      raise Error.new("va.yaml node must have type switch and the switch role; run `voipappz setup` first")
    end

    {"internal" => node.profile["ip_address_internal"]?,
     "external" => node.profile["ip_address_external"]?}.each do |label, value|
      unless value && NetValidation.usable_node_ipv4?(value)
        raise Error.new("va.yaml node #{label} address must be a non-loopback IPv4 address")
      end
    end
  end

  private def api_root(raw_url : String) : String
    base = raw_url.strip.rstrip("/")
    raise Error.new("va.yaml mothership.url is missing") if base.empty?
    base.ends_with?("/api") ? base : "#{base}/api"
  end

  private def node_payload(node : NodeConfig) : String
    {
      uuid:    node.uuid,
      name:    node.name,
      type:    node.type,
      roles:   node.roles,
      profile: node.profile,
    }.to_json
  end

  # GET first makes a repeated registration a true no-op. A changed YAML is
  # reconciled with PATCH, while a conflict after the initial 404 closes the
  # create race with one confirming GET.
  private def create_unless_present(api_root : String, node : NodeConfig,
                                    authorization : String) : {HTTP::Client::Response, Operation}
    collection = "#{api_root}/nodes"
    member = "#{collection}/#{node.uuid}"

    lookup = request("GET", member, authorization)
    case lookup.status_code
    when 200
      reconcile_existing(lookup, member, node, authorization)
    when 404
      created = request("POST", collection, authorization, node_payload(node))
      case created.status_code
      when 200, 201
        {created, Operation::Created}
      when 406, 409
        raced_lookup = request("GET", member, authorization)
        case raced_lookup.status_code
        when 200
          reconcile_existing(raced_lookup, member, node, authorization)
        when 404
          # The UUID still does not exist, so this was a validation conflict
          # (most commonly the API's globally unique node name), not a create
          # race. Preserve the actionable POST response.
          raise_response!(created, "create", authorization)
        else
          raise_response!(raced_lookup, "lookup after create conflict", authorization)
        end
      else
        raise_response!(created, "create", authorization)
      end
    when 401, 403
      raise Error.new("mothership authorization failed (HTTP #{lookup.status_code})")
    else
      raise Error.new("mothership rejected node lookup (HTTP #{lookup.status_code})")
    end
  end

  private def reconcile_existing(response : HTTP::Client::Response, member : String,
                                 node : NodeConfig, authorization : String) : {HTTP::Client::Response, Operation}
    # A node the mothership declares in its OWN va.yaml has no row to update:
    # `editable: false` is the API saying so, and PATCH answers 406 whatever the
    # body carries. There is nothing here for the node to reconcile, so the
    # record standing is the whole of registration.
    return {response, Operation::Existing} if mothership_owned?(response.body)
    return {response, Operation::Existing} if response_matches?(response.body, node)

    updated = request("PATCH", member, authorization,
      node_payload(node, merged_profile(response.body, node)))
    expect_status!(updated, 200, "update", authorization)
    {updated, Operation::Updated}
  end

  # The API's own words for "this came from my config file, not my table":
  # Serializers::Node emits source and editable on every node.
  private def mothership_owned?(body : String) : Bool
    fields = JSON.parse(body).as_h? || return false
    return true if fields["editable"]?.try(&.as_bool?) == false
    fields["source"]?.try(&.as_s?) == "va.yaml"
  rescue JSON::ParseException
    false
  end

  private def response_matches?(body : String, node : NodeConfig) : Bool
    fields = JSON.parse(body).as_h? || raise Error.new("mothership returned an invalid node response")
    uuid = fields["uuid"]?.try(&.as_s?) || return false
    name = fields["name"]?.try(&.as_s?) || return false
    profile = fields["profile"]?.try(&.as_h?) || return false
    profile_matches = node.profile.all? do |key, value|
      profile[key]?.try(&.as_s?) == value
    end

    # type and roles are not compared: see node_payload — they are the
    # mothership's to set, so a difference there is not drift to reconcile.
    uuid.downcase == node.uuid.downcase && name == node.name && profile_matches
  rescue ex : JSON::ParseException
    raise Error.new("mothership returned an invalid node response")
  end

  private def merged_profile(body : String, node : NodeConfig) : Hash(String, JSON::Any)
    fields = JSON.parse(body).as_h? || raise Error.new("mothership returned an invalid node response")
    profile = fields["profile"]?.try(&.as_h?).try(&.dup) ||
              raise Error.new("mothership returned an invalid node profile")
    node.profile.each { |key, value| profile[key] = JSON::Any.new(value) }
    profile
  rescue ex : JSON::ParseException
    raise Error.new("mothership returned an invalid node response")
  end

  # THE UPDATE CARRIES NEITHER type NOR roles. What a node IS in the
  # deployment — a switch, a db, which roles it plays — is the mothership's
  # decision, made when the record was created and often in its own va.yaml.
  # A node reporting in has one thing to say: where it can be reached. Sending
  # type/roles asked the API to rewrite another machine's identity and earned
  # a 406 on any record the mothership owns.
  private def node_payload(node : NodeConfig, profile : Hash(String, JSON::Any)) : String
    {
      uuid:    node.uuid,
      name:    node.name,
      profile: profile,
    }.to_json
  end

  private def expect_status!(response : HTTP::Client::Response, expected : Int32,
                             action : String, authorization : String) : Nil
    return if response.status_code == expected
    raise_response!(response, action, authorization)
  end

  private def raise_response!(response : HTTP::Client::Response, action : String,
                              authorization : String) : NoReturn
    if response.status_code == 401 || response.status_code == 403
      raise Error.new("mothership authorization failed (HTTP #{response.status_code})")
    end
    detail = response_detail(response.body, authorization)
    suffix = detail.empty? ? "" : ": #{detail}"
    raise Error.new("mothership rejected node #{action} (HTTP #{response.status_code})#{suffix}")
  end

  private def response_detail(body : String, authorization : String) : String
    raw = begin
      json = JSON.parse(body)
      object = json.as_h?
      object.try(&.["error"]?).try(&.as_s?) ||
      object.try(&.["message"]?).try(&.as_s?) || body
    rescue JSON::ParseException
      body
    end
    compact = raw.gsub(/\s+/, " ").strip
    safe = redact(compact, authorization)
    safe[0, Math.min(safe.size, 240)]
  end

  private def request(method : String, url : String, authorization : String,
                      body : String? = nil) : HTTP::Client::Response
    uri = URI.parse(url)
    host = uri.host
    unless NetValidation.safe_mothership_transport?(uri.scheme, host)
      raise Error.new("va.yaml mothership.url must use HTTPS (plain HTTP is allowed only on loopback)")
    end

    headers = HTTP::Headers{
      "Accept"        => "application/json",
      "Authorization" => authorization,
    }
    headers["Content-Type"] = "application/json" if body

    client = https_client(uri)
    client.read_timeout = 15.seconds
    client.exec(method, uri.request_target, headers, body)
  rescue ex : Error
    raise ex
  rescue ex : OpenSSL::SSL::Error
    raise Error.new(tls_failure_message(URI.parse(url), ex.message.to_s))
  rescue ex
    raise Error.new("mothership request failed: #{redact(ex.message.to_s, authorization)}")
  ensure
    client.try(&.close)
  end

  # ── TLS: verify, or verify against a PIN. No flag. ──────────────────────
  #
  # A mothership reached by IP, or self-signed, cannot pass normal
  # verification: the name is wrong or the chain is unknown. The installer
  # already answers that by saving the chain the mothership presented to
  # ca-bundle.pem beside va.yaml. When that file exists, THIS is the trust:
  # the chain must verify against it (verify_mode PEER, so a different
  # certificate — a different machine, a MITM — is refused), and the name is
  # not checked, because the pin IS the identity. No environment switch,
  # nothing to skip, nothing for an operator to type.
  #
  # Crystal applies the hostname/IP check inside OpenSSL::SSL::Socket::Client
  # when it is given a hostname; building the socket here without one is what
  # turns "verify the chain" into "verify the pin".
  CA_BUNDLE_NAME = "ca-bundle.pem"
  @@config_dir : String? = nil

  # `sync` pulls va.yaml from the same mothership and must trust it the same
  # way: one pin, one client, no second rule to drift.
  def config_dir=(dir : String)
    @@config_dir = dir
  end

  # Where the pin lives: SSL_CERT_FILE (OpenSSL's own name, what the
  # installer exports) or ca-bundle.pem next to the va.yaml being registered.
  def ca_bundle_path : String?
    if env = ENV["SSL_CERT_FILE"]?.presence
      return env
    end
    dir = @@config_dir
    return nil unless dir
    path = File.join(dir, CA_BUNDLE_NAME)
    File.exists?(path) ? path : nil
  end

  def https_client(uri : URI) : HTTP::Client
    host = uri.host.to_s
    port = uri.port || (uri.scheme == "https" ? 443 : 80)
    bundle = uri.scheme == "https" ? ca_bundle_path : nil
    unless bundle
      client = HTTP::Client.new(uri)
      client.connect_timeout = 10.seconds
      return client
    end
    context = OpenSSL::SSL::Context::Client.new
    context.ca_certificates = bundle
    context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
    tcp = TCPSocket.new(host, port, connect_timeout: 10.seconds)
    ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true, hostname: nil)
    HTTP::Client.new(ssl, host, port)
  end

  # A TLS failure said as a TLS failure. The raw OpenSSL line
  # ("SSL_connect: error:0A000086:SSL routines::certificate verify failed")
  # names neither the host nor what fixes it. Public and pure, so the wording
  # is pinned by a spec.
  def tls_failure_message(uri : URI, reason : String) : String
    host = uri.host.to_s
    what = if reason.includes?("certificate verify failed")
             "its certificate could not be verified"
           elsif reason.includes?("wrong version number") || reason.includes?("unknown protocol")
             "it did not answer TLS on port #{uri.port || 443} (a plain-HTTP port, or not the mothership)"
           else
             "the TLS handshake failed"
           end
    pin = ca_bundle_path
    String.build do |io|
      io << "cannot register with " << uri.scheme << "://" << host << ": " << what << ".\n"
      if pin
        io << "  the certificate it presented does not match the pinned chain in " << pin << ".\n"
        io << "  if the mothership's certificate was reissued, save the new chain there (the installer does:\n"
        io << "  openssl s_client -connect " << host << ":" << (uri.port || 443) << " -showcerts) and register again.\n"
      else
        io << "  self-signed, issued for a name this URL does not use, or a chain the image does not trust.\n"
        io << "  fix one of:\n"
        io << "    - reach the mothership by the name on its certificate (mothership.url in va.yaml)\n"
        io << "    - pin the chain it presents: save it as " << CA_BUNDLE_NAME << " next to va.yaml\n"
        io << "      (the installer does this; or SSL_CERT_FILE=/path/to/chain.pem)\n"
      end
      io << "  openssl said: " << reason
    end
  end

  private def validate_response_uuid!(body : String, expected_uuid : String) : Nil
    fields = JSON.parse(body).as_h? || raise Error.new("mothership returned an invalid node response")
    uuid = fields["uuid"]?.try(&.as_s?) || raise Error.new("mothership node response has no uuid")
    raise Error.new("mothership returned a different node uuid") unless uuid.downcase == expected_uuid.downcase
  rescue ex : JSON::ParseException
    raise Error.new("mothership returned an invalid node response")
  end

  private def redact(message : String, authorization : String) : String
    clean = authorization.strip
    return message if clean.empty?
    credentials = clean.partition(' ')[2]
    message.gsub(clean, "[REDACTED]").gsub(credentials, "[REDACTED]")
  end
end
