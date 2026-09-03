require "admiral"
require "../helpers/docker"
require "../helpers/colors"
require "../helpers/ssh"
require "../helpers/table"

module VoIPAppz::Commands
  class Backup < Admiral::Command
    define_help description: "Backup and restore data"

    define_flag restore : Bool,
      description: "Restore from backup instead of creating one",
      default: false,
      short: r
    define_flag list : Bool,
      description: "List available backup files in backups/",
      default: false,
      short: l
    define_flag db_only : Bool,
      description: "Backup/restore database only (pg_dump)",
      default: false
    define_flag dir : String,
      description: "Backup dir (full restore) or dump file (.sql.gz / .tar.gz / .dump)"
    define_flag db : String,
      description: "Target database name (override; default: derived from filename)"
    define_flag remote : Bool,
      description: "Backup remote database",
      default: false
    define_flag host : String,
      description: "Remote host (for --remote)",
      short: h
    define_flag user : String,
      description: "Remote SSH user",
      default: "root",
      short: u
    define_flag password : String,
      description: "SSH password",
      short: p
    define_flag key : String,
      description: "SSH key path",
      default: "~/.ssh/id_rsa",
      short: k

    def run
      if flags.list
        list_backups
      elsif flags.restore
        restore_backup
      elsif flags.remote
        backup_remote_db
      elsif flags.db_only
        backup_db
      else
        backup_full
      end
    end

    # Print every restore candidate under backups/. Both the legacy
    # tar archives (full backups in subdirs) and the gzipped pg_dumps
    # (Ofelia and `--db-only`) show up so the operator can pick either.
    private def list_backups
      project_dir = VoIPAppz::Project.root
      backups_dir = File.join(project_dir, "backups")
      unless Dir.exists?(backups_dir)
        puts VoIPAppz::Colors.warning("No backups/ directory yet — run `voipappz backup` first.")
        return
      end

      entries = [] of {String, String, Int64}
      Dir.each_child(backups_dir) do |name|
        path = File.join(backups_dir, name)
        info = File.info(path)
        if File.directory?(path) && File.exists?(File.join(path, "postgres_data.tar.gz"))
          entries << {name, "full", info.size}
        elsif File.file?(path) && name.ends_with?(".sql.gz")
          entries << {name, "db", info.size}
        end
      end

      if entries.empty?
        puts VoIPAppz::Colors.warning("No restore candidates found in backups/.")
        return
      end

      cols = [
        VoIPAppz::Table::Column.new("Name", 38),
        VoIPAppz::Table::Column.new("Type", 6),
        VoIPAppz::Table::Column.new("Size", 12),
      ]
      rows = entries.sort_by { |e| e[0] }.reverse.map do |name, kind, size|
        [name, kind, human_size(size)]
      end
      puts VoIPAppz::Table.render(cols, rows, "Available backups (backups/)")
      puts ""
      puts VoIPAppz::Colors.dim("  Restore: voipappz backup --restore --dir backups/<name>")
    end

    private def human_size(bytes : Int64) : String
      units = ["B", "KB", "MB", "GB"]
      i = 0
      v = bytes.to_f
      while v >= 1024 && i < units.size - 1
        v /= 1024
        i += 1
      end
      "%.1f %s" % [v, units[i]]
    end

    private def backup_full
      project_dir = VoIPAppz::Project.root
      timestamp = Time.local.to_s("%Y%m%d_%H%M%S")
      backup_dir = File.join(project_dir, "backups", timestamp)

      puts VoIPAppz::Colors.bold("Creating full backup...")
      Dir.mkdir_p(backup_dir)

      # Backup postgres data volume
      puts VoIPAppz::Colors.cyan("  Backing up PostgreSQL data...")
      process = Process.new(
        "docker",
        ["run", "--rm",
         "-v", "voipappz-node_postgres_data:/data",
         "-v", "#{backup_dir}:/backup",
         "alpine", "tar", "czf", "/backup/postgres_data.tar.gz", "-C", "/data", "."],
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      process.wait

      # Backup secrets
      secrets_dir = File.join(project_dir, "secrets")
      if Dir.exists?(secrets_dir)
        puts VoIPAppz::Colors.cyan("  Backing up secrets...")
        target_dir = File.join(backup_dir, "secrets")
        Dir.mkdir_p(target_dir)
        Dir.each_child(secrets_dir) do |file|
          src = File.join(secrets_dir, file)
          File.copy(src, File.join(target_dir, file)) if File.file?(src)
        end
      end

      # Backup compose file and .env
      puts VoIPAppz::Colors.cyan("  Backing up configuration...")
      ["docker-compose.yaml", ".env"].each do |f|
        src = File.join(project_dir, f)
        File.copy(src, File.join(backup_dir, f)) if File.exists?(src)
      end

      puts VoIPAppz::Colors.green("Backup created in backups/#{timestamp}")
    end

    private def backup_db
      project_dir = VoIPAppz::Project.root
      timestamp = Time.local.to_s("%Y%m%d_%H%M%S")
      backups_dir = File.join(project_dir, "backups")
      Dir.mkdir_p(backups_dir)

      # Match the Ofelia daily-dump filename pattern: <db>-<ISO ts>.sql.gz.
      # The current product backup is the primary API database only.
      database = "voipappz"
      # gzip on-the-fly so `backup --list` finds it and `backup --restore`
      # can pipe it straight into psql.
      output_file = File.join(backups_dir, "#{database}-#{timestamp}.sql.gz")
      puts VoIPAppz::Colors.bold("Backing up database...")

      # --clean --if-exists makes restore idempotent: each CREATE is
      # prefixed by DROP IF EXISTS, so restoring on top of a populated
      # DB doesn't choke on "relation already exists".
      pg_dump = Process.new(
        "docker",
        ["compose", "-f", "docker-compose.yaml", "exec", "-T", "postgres",
         "pg_dump", "-U", "postgres", "--clean", "--if-exists", database],
        chdir: project_dir,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Inherit,
      )
      gz_stdout = File.open(output_file, "w")
      gzip = Process.new("gzip", ["-c"],
        input: pg_dump.output,
        output: gz_stdout,
        error: Process::Redirect::Inherit,
      )
      pg_status = pg_dump.wait
      gzip_status = gzip.wait
      gz_stdout.close

      if pg_status.success? && gzip_status.success?
        key = "#{database}-#{timestamp}.sql.gz"
        puts VoIPAppz::Colors.green("Database backup saved to backups/#{key}")
        upload_to_minio(output_file, key, timestamp)
      else
        STDERR.puts VoIPAppz::Colors.red("Database backup failed (pg_dump=#{pg_status.exit_code} gzip=#{gzip_status.exit_code})")
        File.delete(output_file) if File.exists?(output_file)
        exit 1
      end
    end

    # Upload the dump to MinIO `local/backup` and refresh the public
    # heartbeat at `local/recordings/health/last-backup.txt` so Gatus's
    # "Backup heartbeat present" probe stays green.
    private def upload_to_minio(local_path : String, key : String, timestamp : String)
      project_dir = VoIPAppz::Project.root
      env = load_env(project_dir)
      access = env["VA_S3_KEY"]?
      secret = env["VA_S3_SECRET"]?
      if access.nil? || secret.nil? || access.empty? || secret.empty?
        puts VoIPAppz::Colors.warning("Skipping MinIO upload — VA_S3_KEY/VA_S3_SECRET not set")
        return
      end

      # mc image's entrypoint is `mc`, so `sh -c ...` becomes `mc sh -c ...`
      # which fails. Override entrypoint to /bin/sh and pass our shell
      # script as the command. The script does cp + heartbeat in one shot.
      cmd = [
        "run", "--rm", "--network", "host",
        "--entrypoint", "/bin/sh",
        "-e", "MC_HOST_local=http://#{access}:#{secret}@127.0.0.1:9000",
        "-v", "#{File.dirname(local_path)}:/dump:ro",
        "minio/mc", "-c",
        "/usr/bin/mc cp /dump/#{File.basename(local_path)} local/backup/#{key} && " \
        "echo '#{timestamp}' | /usr/bin/mc pipe local/recordings/health/last-backup.txt",
      ]
      status = Process.new("docker", cmd,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit).wait
      # A swallowed mc failure once printed "Uploaded ✔" right under mc's own
      # "Bucket does not exist" error — a backup that claims success while the
      # dump never left the box is worse than a loud failure.
      unless status.success?
        STDERR.puts VoIPAppz::Colors.red("MinIO upload failed (exit #{status.exit_code}) — dump kept locally at backups/#{key}")
        exit 1
      end
      puts VoIPAppz::Colors.green("Uploaded to s3://backup/#{key} + refreshed heartbeat")
    end

    private def load_env(project_dir : String) : Hash(String, String)
      env = {} of String => String
      path = File.join(project_dir, ".env")
      return env unless File.exists?(path)
      File.each_line(path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?("#")
        if line.includes?("=")
          k, v = line.split("=", 2)
          env[k.strip] = v.strip.gsub(/^["']|["']$/, "")
        end
      end
      env
    end

    private def backup_remote_db
      host = flags.host
      if host.nil? || host.empty?
        STDERR.puts VoIPAppz::Colors.red("Error: --host required for remote backup")
        exit 1
      end

      project_dir = VoIPAppz::Project.root
      timestamp = Time.local.to_s("%Y%m%d_%H%M%S")
      backups_dir = File.join(project_dir, "backups")
      Dir.mkdir_p(backups_dir)

      database = "voipappz"
      output_file = File.join(backups_dir, "remote_#{database}_#{timestamp}.sql")
      puts VoIPAppz::Colors.bold("Backing up remote database from #{host}...")

      key_path = flags.key.gsub("~", ENV["HOME"])
      exit_code, output = VoIPAppz::SSH.run(
        host, flags.user,
        "cd /opt/va && docker compose exec -T postgres pg_dump -U postgres #{database}",
        flags.password, key_path, 22,
        capture: true
      )

      if exit_code == 0
        File.write(output_file, output)
        puts VoIPAppz::Colors.green("Remote backup saved to backups/remote_freeswitch_#{timestamp}.sql")
      else
        STDERR.puts VoIPAppz::Colors.red("Remote database backup failed")
        exit 1
      end
    end

    private def restore_backup
      target = flags.dir
      if target.nil? || target.empty?
        STDERR.puts VoIPAppz::Colors.red("Error: --dir required for restore")
        STDERR.puts "Usage: voipappz backup --restore --dir backups/<dir-or-file>"
        STDERR.puts "       voipappz backup --list   # show candidates"
        exit 1
      end

      # Single-file dump path. Mirrors the postgres image Makefile's
      # `restore-db` target — format detected by extension:
      #   .sql.gz → gunzip | psql
      #   .tar.gz → gunzip | pg_restore --clean --if-exists
      #   .dump   → pg_restore --clean --if-exists < file  (custom -Fc)
      if File.file?(target)
        if target.ends_with?(".sql.gz")
          restore_dump(target, :sql_gz)
          return
        elsif target.ends_with?(".tar.gz")
          restore_dump(target, :tar_gz)
          return
        elsif target.ends_with?(".dump")
          restore_dump(target, :custom)
          return
        end
      end

      unless Dir.exists?(target)
        STDERR.puts VoIPAppz::Colors.red("Backup target not found: #{target}")
        exit 1
      end

      puts VoIPAppz::Colors.yellow("WARNING: This will overwrite current data!")
      print "Continue? (y/N) "
      confirm = gets
      unless confirm && confirm.strip.downcase == "y"
        puts "Cancelled."
        return
      end

      project_dir = VoIPAppz::Project.root
      backup_dir = target

      puts VoIPAppz::Colors.bold("Restoring from #{backup_dir}...")

      # Stop services
      puts VoIPAppz::Colors.cyan("  Stopping services...")
      VoIPAppz::Docker.compose!(["down"])

      # Restore postgres data
      pg_archive = File.join(backup_dir, "postgres_data.tar.gz")
      if File.exists?(pg_archive)
        puts VoIPAppz::Colors.cyan("  Restoring PostgreSQL data...")
        process = Process.new(
          "docker",
          ["run", "--rm",
           "-v", "voipappz-node_postgres_data:/data",
           "-v", "#{File.expand_path(backup_dir)}:/backup",
           "alpine", "tar", "xzf", "/backup/postgres_data.tar.gz", "-C", "/data"],
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit,
        )
        process.wait
      end

      # Restore secrets
      secrets_src = File.join(backup_dir, "secrets")
      if Dir.exists?(secrets_src)
        puts VoIPAppz::Colors.cyan("  Restoring secrets...")
        secrets_dst = File.join(project_dir, "secrets")
        Dir.mkdir_p(secrets_dst)
        Dir.each_child(secrets_src) do |file|
          File.copy(File.join(secrets_src, file), File.join(secrets_dst, file))
        end
      end

      puts VoIPAppz::Colors.green("Restore completed")
    end

    # Strip dump extensions and split on `-` to get the DB name. Supports
    # both Ofelia's `freeswitch-<ts>.sql.gz` and the postgres image
    # Makefile's plain `voipappz.dump` / `freeswitch.tar.gz` style.
    private def derive_target_db(basename : String) : String
      stem = basename
      [".sql.gz", ".tar.gz", ".dump"].each do |ext|
        if stem.ends_with?(ext)
          stem = stem[0...stem.size - ext.size]
          break
        end
      end
      stem.split("-", 2).first? || "voipappz"
    end

    # Restore a single dump file into the running db container. Mirrors the
    # va-voipbox-postgres Makefile's `restore-db` target: format is detected
    # by extension and routed to psql or pg_restore accordingly. Pipes the
    # local file straight through `docker compose exec -T db ...` so no
    # extra disk is consumed in the container.
    private def restore_dump(file_path : String, format : Symbol)
      project_dir = VoIPAppz::Project.root
      basename = File.basename(file_path)
      target_db = flags.db.presence || derive_target_db(basename)

      fmt_label = case format
                  when :sql_gz then "plain SQL (gzip)"
                  when :tar_gz then "tar (gzip)"
                  when :custom then "custom (pg_dump -Fc)"
                  else              "unknown"
                  end

      puts VoIPAppz::Colors.yellow("WARNING: Restoring #{basename} [#{fmt_label}] into '#{target_db}' database. Existing data will be overwritten.")
      print "Continue? (y/N) "
      confirm = gets
      unless confirm && confirm.strip.downcase == "y"
        puts "Cancelled."
        return
      end

      puts VoIPAppz::Colors.bold("Restoring #{basename}...")

      case format
      when :sql_gz
        restore_sql_gz(project_dir, file_path, basename, target_db)
      when :tar_gz
        restore_pg_restore_gz(project_dir, file_path, basename, target_db)
      when :custom
        restore_pg_restore_custom(project_dir, file_path, basename, target_db)
      end
    end

    # gunzip → sed (CASCADE) → psql.
    # pg_dump --clean --if-exists emits DROP TABLE IF EXISTS without CASCADE,
    # which fails on tables with FK references (freeswitch's acc / acc_cdrs).
    # Inject CASCADE via sed before psql sees the SQL.
    private def restore_sql_gz(project_dir, file_path, basename, target_db)
      reader = File.open(file_path, "r")
      gunzip = Process.new("gunzip", ["-c"],
        input: reader, output: Process::Redirect::Pipe,
        error: Process::Redirect::Inherit)
      sed = Process.new("sed",
        ["-E", "s/^DROP TABLE IF EXISTS ([^;]+);$/DROP TABLE IF EXISTS \\1 CASCADE;/"],
        input: gunzip.output, output: Process::Redirect::Pipe,
        error: Process::Redirect::Inherit)
      psql = Process.new(
        "docker",
        ["compose", "-f", "docker-compose.yaml", "exec", "-T", "db",
         "psql", "-U", "postgres", "-d", target_db, "-v", "ON_ERROR_STOP=1"],
        chdir: project_dir,
        input: sed.output,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      gunzip_status = gunzip.wait
      sed_status = sed.wait
      psql_status = psql.wait
      reader.close

      if gunzip_status.success? && sed_status.success? && psql_status.success?
        puts VoIPAppz::Colors.green("Restore complete: #{basename} → #{target_db}")
      else
        STDERR.puts VoIPAppz::Colors.red("Restore failed (gunzip=#{gunzip_status.exit_code} sed=#{sed_status.exit_code} psql=#{psql_status.exit_code})")
        exit 1
      end
    end

    # gunzip → pg_restore --clean --if-exists  (pg_dump -Ft tar archive).
    private def restore_pg_restore_gz(project_dir, file_path, basename, target_db)
      reader = File.open(file_path, "r")
      gunzip = Process.new("gunzip", ["-c"],
        input: reader, output: Process::Redirect::Pipe,
        error: Process::Redirect::Inherit)
      pg_restore = Process.new(
        "docker",
        ["compose", "-f", "docker-compose.yaml", "exec", "-T", "db",
         "pg_restore", "-U", "postgres", "-d", target_db,
         "--clean", "--if-exists", "--no-owner", "--no-privileges"],
        chdir: project_dir,
        input: gunzip.output,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      gunzip_status = gunzip.wait
      pgr_status = pg_restore.wait
      reader.close

      if gunzip_status.success? && pgr_status.success?
        puts VoIPAppz::Colors.green("Restore complete: #{basename} → #{target_db}")
      else
        STDERR.puts VoIPAppz::Colors.red("Restore failed (gunzip=#{gunzip_status.exit_code} pg_restore=#{pgr_status.exit_code})")
        exit 1
      end
    end

    # pg_restore --clean --if-exists < file  (pg_dump -Fc custom archive).
    private def restore_pg_restore_custom(project_dir, file_path, basename, target_db)
      reader = File.open(file_path, "r")
      pg_restore = Process.new(
        "docker",
        ["compose", "-f", "docker-compose.yaml", "exec", "-T", "db",
         "pg_restore", "-U", "postgres", "-d", target_db,
         "--clean", "--if-exists", "--no-owner", "--no-privileges"],
        chdir: project_dir,
        input: reader,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      pgr_status = pg_restore.wait
      reader.close

      if pgr_status.success?
        puts VoIPAppz::Colors.green("Restore complete: #{basename} → #{target_db}")
      else
        STDERR.puts VoIPAppz::Colors.red("Restore failed (pg_restore=#{pgr_status.exit_code})")
        exit 1
      end
    end
  end
end
