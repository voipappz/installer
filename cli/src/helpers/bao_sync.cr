require "./bao"
require "./docker"

# Orchestrates the two directions between disk and OpenBao — the ONE place that
# moves a host's identity in and out of the secret store:
#
#   push : disk → Bao   (seed the source of truth from setup-generated files)
#   dump : Bao → disk   (regenerate the two artifacts: .env + config/va.yaml)
#
# Model (2026-07-08): OpenBao is the single source of truth. `voipappz setup`
# saves the generated config+secrets INTO Bao; `voipappz up` and
# `voipappz secrets --sync` DUMP them back out to `.env` (for docker compose)
# and `config/va.yaml` (structured config). The disk files are derived, Bao is
# authoritative. There is no separate `voipappz.yaml` snapshot.
#
# These methods do NO printing — they return counts so each caller (setup, up,
# secrets) keeps its own output style. Bao must be unsealed before calling
# push/dump (callers check `Bao.status`).
module VoIPAppz::BaoSync
  extend self

  # .env names whose VALUES are secrets and belong in Bao. Anything matching
  # PASSWORD/SECRET/TOKEN/MASTER/_KEY is sensitive; the explicit list adds the
  # credential-bearing URLs so a rotated password propagates through them.
  SENSITIVE_URL_KEYS = %w[
    VA_NATS_URL VA_DATABASE_URL VA_DATABASE_KAMAILIO_URL
    VA_DATABASE_FREESWITCH_URL VA_REDIS_URL
  ]

  def sensitive?(key : String) : Bool
    return true if SENSITIVE_URL_KEYS.includes?(key)
    !!(key =~ /PASSWORD|SECRET|TOKEN|MASTER|_KEY$|_KEY_/)
  end

  record PushResult, keys : Int32, files : Array(String)
  record DumpResult, keys : Int32, files : Array(String)

  # Read .env → { KEY => value } for the sensitive keys only (non-empty).
  def sensitive_env_pairs(project_dir : String) : Hash(String, String)
    pairs = {} of String => String
    path = File.join(project_dir, ".env")
    return pairs unless File.exists?(path)
    File.each_line(path) do |line|
      l = line.strip
      next if l.empty? || l.starts_with?("#") || !l.includes?("=")
      k, v = l.split("=", 2)
      k = k.strip
      v = v.strip
      pairs[k] = v if sensitive?(k) && !v.empty?
    end
    pairs
  end

  # Repo-relative files that make up a host's identity, pushed whole to Bao:
  # config/va.yaml, .env, and every secrets/*.txt.
  def identity_files(project_dir : String) : Array(String)
    files = [] of String
    files << "config/va.yaml" if File.exists?(File.join(project_dir, "config", "va.yaml"))
    files << ".env" if File.exists?(File.join(project_dir, ".env"))
    secrets_dir = File.join(project_dir, "secrets")
    if Dir.exists?(secrets_dir)
      Dir.glob(File.join(secrets_dir, "*.txt")).sort.each do |p|
        files << "secrets/#{File.basename(p)}"
      end
    end
    files
  end

  # True if Bao already holds any data (keys or files). Used to decide whether
  # `up` should SEED an empty Bao from disk or DUMP a populated Bao to disk.
  def populated? : Bool
    !VoIPAppz::Bao.get_env.empty? || !VoIPAppz::Bao.list_files.empty?
  end

  # Push sensitive .env keys + identity files INTO Bao. Bao must be unsealed.
  def push(project_dir : String) : PushResult
    pairs = sensitive_env_pairs(project_dir)
    VoIPAppz::Bao.put_env(pairs) unless pairs.empty?
    stored = [] of String
    identity_files(project_dir).each do |rel|
      path = File.join(project_dir, rel)
      content = File.read(path)
      mode = sprintf("%04o", File.info(path).permissions.value)
      ok, _ = VoIPAppz::Bao.put_file(rel, content, mode)
      stored << rel if ok
    end
    PushResult.new(pairs.size, stored)
  end

  # Dump Bao → disk: overwrite the sensitive .env keys with Bao's values, then
  # restore every identity file (content + mode). Regenerates .env + va.yaml.
  def dump(project_dir : String) : DumpResult
    remote = VoIPAppz::Bao.get_env
    env_path = File.join(project_dir, ".env")
    keys_changed = remote.empty? ? 0 : write_env_keys(env_path, remote)
    restored = restore_files(project_dir, VoIPAppz::Bao.list_files)
    DumpResult.new(keys_changed, restored)
  end

  # Write each Bao-stored file back to disk (content + mode). Skips files whose
  # on-disk content already matches. Returns the paths actually (re)written.
  private def restore_files(project_dir : String, files : Array(String)) : Array(String)
    restored = [] of String
    files.each do |rel|
      sf = VoIPAppz::Bao.get_file(rel)
      next unless sf
      path = File.join(project_dir, rel)
      next if File.exists?(path) && File.read(path) == sf.content # unchanged
      Dir.mkdir_p(File.dirname(path))
      # target may be read-only (0444/0400): make writable, write, re-lock.
      File.chmod(path, 0o600) rescue nil if File.exists?(path)
      File.write(path, sf.content)
      File.chmod(path, sf.mode.to_i(8)) rescue nil
      restored << rel
    end
    restored
  end

  # Overwrite each KEY= line in .env with the Bao value (append if absent).
  # Returns how many lines actually changed. Preserves order/comments.
  private def write_env_keys(env_path : String, keys : Hash(String, String)) : Int32
    lines = File.exists?(env_path) ? File.read_lines(env_path) : [] of String
    seen = Set(String).new
    changed = 0
    rendered = lines.map do |line|
      l = line.strip
      if !l.starts_with?("#") && l.includes?("=")
        k = l.split("=", 2).first.strip
        if keys.has_key?(k)
          seen << k
          newline = "#{k}=#{keys[k]}"
          changed += 1 if newline != line
          next newline
        end
      end
      line
    end
    keys.each do |k, v|
      next if seen.includes?(k)
      rendered << "#{k}=#{v}"
      changed += 1
    end
    File.write(env_path, rendered.join("\n") + "\n")
    changed
  end
end
