require "json"
require "base64"
require "./colors"
require "./docker"

# Thin wrapper around the `openbao` container's `bao` CLI. This is the plumbing
# behind `voipappz secrets --bao-init / --push / --sync / --bao-status`.
#
# Model (chosen 2026-07-05): OpenBao is the SOURCE OF TRUTH for the stack's
# infra secrets. The CLI pushes .env/secrets/*.txt values INTO Bao and can
# render them back OUT to .env. Running services keep reading plain ENV — they
# do NOT talk to Bao at runtime (see config/openbao/openbao.hcl).
#
# NB this is unrelated to voipappz-api's `$vault` (an in-process AES-GCM
# encrypt-at-rest lib for tenant provider secrets in Postgres). That protects
# DB rows; THIS protects the infra keys. VA_VAULT_MASTER_KEY (which unlocks the
# api vault) is itself one of the keys stored here.
module VoIPAppz::Bao
  extend self

  CONTAINER    = "openbao"
  ADDR         = "http://127.0.0.1:8200"
  KV_MOUNT     = "va"          # kv-v2 mount; keys live under va/env and va/files/*
  ENV_PATH     = "va/env"      # single kv-v2 secret whose fields ARE the .env keys
  FILES_PREFIX = "va/files"    # whole files (va.yaml, .env, secrets/*.txt) live under here

  # The two irreducible bootstrap secrets: everything else lives inside Bao,
  # but you need these to unseal it and to authenticate. 0400, next to the
  # other secrets/*.txt.
  def unseal_key_file : String
    File.join(VoIPAppz::Docker.project_dir, "secrets", "openbao_unseal.txt")
  end

  def root_token_file : String
    File.join(VoIPAppz::Docker.project_dir, "secrets", "openbao_root.txt")
  end

  def root_token : String?
    p = root_token_file
    return nil unless File.exists?(p)
    v = File.read(p).strip
    v.empty? ? nil : v
  end

  # True if the openbao container is up (running). Nothing to do if not.
  def container_running? : Bool
    io = IO::Memory.new
    st = Process.run("docker", ["inspect", "-f", "{{.State.Running}}", CONTAINER],
      output: io, error: Process::Redirect::Close)
    st.success? && io.to_s.strip == "true"
  end

  # Run `bao <args>` inside the container. Token (when given) is passed via env
  # so it isn't baked into the argv the way a `-token=` flag would be. Returns
  # {exit_code, combined_output}.
  def exec(args : Array(String), token : String? = nil) : {Int32, String}
    cmd = ["exec"]
    cmd << "-e" << "BAO_ADDR=#{ADDR}"
    cmd << "-e" << "BAO_TOKEN=#{token}" if token
    cmd << CONTAINER << "bao"
    cmd.concat(args)
    io = IO::Memory.new
    st = Process.run("docker", cmd, output: io, error: io)
    {st.exit_code, io.to_s}
  end

  record Status, running : Bool, initialized : Bool, sealed : Bool

  # Parse `bao status -format=json`. Exit code is 0 unsealed / 2 sealed / non-2
  # error, but the JSON carries the booleans regardless, so we read those.
  def status : Status
    return Status.new(false, false, true) unless container_running?
    code, output = exec(["status", "-format=json"])
    json = (JSON.parse(output) rescue nil)
    if json
      Status.new(true,
        json["initialized"]?.try(&.as_bool?) || false,
        json["sealed"]?.try(&.as_bool?) != false)
    else
      # No parseable JSON → server not answering yet.
      Status.new(true, false, true)
    end
  end

  # Initialise a fresh Bao: 1 key share / threshold 1 (single-node PBX box).
  # Persists the unseal key + root token to secrets/openbao_*.txt (0400).
  # Idempotent: if already initialised and the bootstrap files exist, no-op.
  # Returns {ok, message}.
  def init : {Bool, String}
    st = status
    return {false, "openbao container is not running (voipappz up -p app)"} unless st.running
    if st.initialized
      return {true, "already initialised"} if File.exists?(unseal_key_file) && File.exists?(root_token_file)
      return {false, "Bao is initialised but secrets/openbao_{unseal,root}.txt are missing — bootstrap secrets lost"}
    end

    code, output = exec(["operator", "init", "-key-shares=1", "-key-threshold=1", "-format=json"])
    return {false, "init failed: #{output.strip}"} unless code == 0
    json = JSON.parse(output)
    key = json["unseal_keys_b64"].as_a.first.as_s
    tok = json["root_token"].as_s
    write_secret(unseal_key_file, key)
    write_secret(root_token_file, tok)
    {true, "initialised (unseal key + root token → secrets/openbao_*.txt, 0400)"}
  end

  # Unseal using the stored key. Idempotent (no-op if already unsealed).
  def unseal : {Bool, String}
    st = status
    return {false, "openbao container is not running"} unless st.running
    return {true, "already unsealed"} unless st.sealed
    return {false, "no unseal key at #{unseal_key_file} — run --bao-init first"} unless File.exists?(unseal_key_file)
    key = File.read(unseal_key_file).strip
    code, output = exec(["operator", "unseal", key])
    st2 = status
    st2.sealed ? {false, "unseal failed: #{output.strip}"} : {true, "unsealed"}
  end

  # Enable the kv-v2 engine at va/. Tolerates the already-enabled case.
  def enable_kv : {Bool, String}
    code, output = exec(["secrets", "enable", "-path=#{KV_MOUNT}", "-version=2", "kv"], token: root_token)
    return {true, "kv mount va/ enabled"} if code == 0
    return {true, "kv mount va/ already enabled"} if output.includes?("already in use") || output.includes?("path is already")
    {false, "enable kv failed: #{output.strip}"}
  end

  # Write all env-style key/values as fields of the single va/env secret.
  # (kv-v2 put replaces the whole secret, so pass the full set each time.)
  def put_env(pairs : Hash(String, String)) : {Bool, String}
    return {true, "nothing to push"} if pairs.empty?
    args = ["kv", "put", ENV_PATH]
    pairs.each { |k, v| args << "#{k}=#{v}" }
    code, output = exec(args, token: root_token)
    code == 0 ? {true, "pushed #{pairs.size} keys → #{ENV_PATH}"} : {false, "put failed: #{output.strip}"}
  end

  # Read the va/env fields back as a Hash. Empty on any error/absence.
  def get_env : Hash(String, String)
    result = {} of String => String
    code, output = exec(["kv", "get", "-format=json", ENV_PATH], token: root_token)
    return result unless code == 0
    json = (JSON.parse(output) rescue nil)
    return result unless json
    data = json.dig?("data", "data")
    return result unless data
    data.as_h.each { |k, v| result[k] = v.as_s? || v.to_s }
    result
  end

  # --- Whole-file storage (va/files/<relpath>) ------------------------------
  #
  # The initial config (config/va.yaml), the full .env, and every secrets/*.txt
  # are stored VERBATIM so Bao is a complete source-of-truth for a host's
  # identity — enough to reconstruct the box from the two bootstrap files alone.
  # Content is base64'd (no shell-hostile bytes on the argv), with the octal
  # file mode kept alongside so `--sync` restores permissions faithfully.

  record StoredFile, content : String, mode : String

  # Store one file. `relpath` is the repo-relative path (e.g. "config/va.yaml"),
  # used verbatim as the kv path suffix so listing round-trips it.
  def put_file(relpath : String, content : String, mode : String) : {Bool, String}
    b64 = Base64.strict_encode(content)
    args = ["kv", "put", "#{FILES_PREFIX}/#{relpath}", "content_b64=#{b64}", "mode=#{mode}"]
    code, output = exec(args, token: root_token)
    code == 0 ? {true, "stored #{relpath}"} : {false, "put #{relpath} failed: #{output.strip}"}
  end

  # Read one stored file back, or nil if absent/corrupt.
  def get_file(relpath : String) : StoredFile?
    code, output = exec(["kv", "get", "-format=json", "#{FILES_PREFIX}/#{relpath}"], token: root_token)
    return nil unless code == 0
    json = (JSON.parse(output) rescue nil)
    return nil unless json
    data = json.dig?("data", "data")
    return nil unless data
    b64 = data["content_b64"]?.try(&.as_s?)
    return nil unless b64
    content = (Base64.decode_string(b64) rescue nil)
    return nil unless content
    mode = data["mode"]?.try(&.as_s?) || "0600"
    StoredFile.new(content, mode)
  end

  # List every stored file path (recursively descends kv "directories").
  # `subpath` is relative to FILES_PREFIX and, for directories, ends with "/".
  def list_files(subpath : String = "") : Array(String)
    result = [] of String
    path = subpath.empty? ? FILES_PREFIX : "#{FILES_PREFIX}/#{subpath}"
    code, output = exec(["kv", "list", "-format=json", path], token: root_token)
    return result unless code == 0
    json = (JSON.parse(output) rescue nil)
    return result unless json && json.as_a?
    json.as_a.each do |entry|
      name = entry.as_s
      rel = "#{subpath}#{name}"
      if name.ends_with?("/")
        result.concat(list_files(rel)) # recurse into the kv "directory"
      else
        result << rel
      end
    end
    result
  end

  private def write_secret(path : String, value : String) : Nil
    Dir.mkdir_p(File.dirname(path))
    File.chmod(path, 0o600) rescue nil if File.exists?(path)
    File.write(path, value)
    File.chmod(path, 0o400) rescue nil
  end
end
