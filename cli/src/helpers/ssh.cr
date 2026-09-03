require "./colors"

module VoIPAppz::SSH
  def self.run(host : String, user : String, command : String,
               password : String? = nil, key : String? = nil, port : Int32 = 22,
               capture : Bool = false) : {Int32, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    args = build_ssh_args(host, user, command, password, key, port)

    if password
      ensure_binary!("sshpass", "Install with: apt-get install sshpass  (or use --key for key-based auth)")
      # Use sshpass for password-based auth
      process = Process.new(
        "sshpass",
        ["-p", password, "ssh"] + args,
        output: capture ? stdout : Process::Redirect::Inherit,
        error: capture ? stderr : Process::Redirect::Inherit,
      )
    else
      process = Process.new(
        "ssh",
        args,
        output: capture ? stdout : Process::Redirect::Inherit,
        error: capture ? stderr : Process::Redirect::Inherit,
      )
    end

    status = process.wait
    {status.exit_code, stdout.to_s.strip}
  end

  def self.run!(host : String, user : String, command : String,
                password : String? = nil, key : String? = nil, port : Int32 = 22) : Nil
    exit_code, _ = run(host, user, command, password, key, port)
    if exit_code != 0
      STDERR.puts Colors.red("SSH command failed: #{command}")
      exit exit_code
    end
  end

  def self.upload(host : String, user : String, local_path : String, remote_path : String,
                  password : String? = nil, key : String? = nil, port : Int32 = 22) : {Int32, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    scp_args = ["-o", "StrictHostKeyChecking=no", "-P", port.to_s]
    scp_args += ["-i", key] if key
    scp_args += [local_path, "#{user}@#{host}:#{remote_path}"]

    if password
      ensure_binary!("sshpass", "Install with: apt-get install sshpass  (or use --key for key-based auth)")
      process = Process.new(
        "sshpass",
        ["-p", password, "scp"] + scp_args,
        output: stdout,
        error: stderr,
      )
    else
      process = Process.new(
        "scp",
        scp_args,
        output: stdout,
        error: stderr,
      )
    end

    status = process.wait
    {status.exit_code, stdout.to_s.strip}
  end

  private def self.ensure_binary!(name : String, hint : String) : Nil
    return if Process.find_executable(name)
    STDERR.puts Colors.red("✘ #{name} not found in PATH")
    STDERR.puts "  #{hint}"
    exit 1
  end

  private def self.build_ssh_args(host : String, user : String, command : String,
                                   password : String?, key : String?, port : Int32) : Array(String)
    args = ["-o", "StrictHostKeyChecking=no", "-p", port.to_s]
    args += ["-i", key] if key && !password
    args += ["#{user}@#{host}", command]
    args
  end
end
