require "./ssh"
require "./colors"

module VoIPAppz
  # Where a deploy step actually runs.
  #
  # Deploying the app plane means running docker compose ON THE NODE — the CLI
  # is already there, the repo is already there, and pushing the same commands
  # through ssh to localhost buys nothing but a key, a daemon and a class of
  # failure that has nothing to do with the deploy. SSH is for the case that
  # genuinely needs it: shipping the `voip` profile to a SEPARATE switch box.
  #
  # Both are the same three operations, so the deploy steps and the verification
  # are written once against this and do not care which one they got.
  abstract class Runner
    # Run a shell command; returns {exit_code, combined output}.
    abstract def run(cmd : String) : {Int32, String}

    # Put a local file at an absolute path on the target.
    abstract def upload(local : String, remote : String) : Bool

    # Directory the compose project lives in on the target.
    abstract def workdir : String

    # Human-readable target, for output.
    abstract def label : String

    # Is this the machine the CLI is running on?
    abstract def local? : Bool

    # Run a command inside the compose project directory.
    #
    # No shell wrapper here: `run` already provides one, and nesting a second
    # `bash -lc` inside it means a box without bash fails with "sh: bash: not
    # found" from a command that had no business needing bash. SSHRunner
    # overrides this, because there the login shell is on the far side.
    def in_project(cmd : String) : {Int32, String}
      run("cd #{workdir} && #{cmd}")
    end

    # `output`, not `out`: `out` is a Crystal keyword (C-binding output
    # parameters). It parses as an assignment target but not as a bare
    # expression, so `return out if ...` fails with "unexpected token".
    def run!(cmd : String) : String
      code, output = run(cmd)
      return output if code == 0
      STDERR.puts VoIPAppz::Colors.red("command failed on #{label} (exit #{code}): #{cmd}")
      STDERR.puts VoIPAppz::Colors.dim(output.lines.last(8).join("\n")) unless output.strip.empty?
      exit code
    end
  end

  # This machine. No ssh, no upload, no provisioning — the files are already
  # where they need to be, which is the whole point.
  class LocalRunner < Runner
    getter workdir : String

    def initialize(@workdir : String = Dir.current)
    end

    # A LOGIN shell, so docker resolves the way it does for an operator — a
    # non-login shell can miss /usr/local/bin on some distros, and then a deploy
    # fails with "docker: not found" on a box that plainly has docker.
    #
    # Resolved, not assumed: bash is not guaranteed (alpine and other minimal
    # images ship busybox sh only), and hardcoding it turns a missing shell into
    # "Error executing process: 'bash'", which says nothing about the deploy.
    class_getter shell : String do
      Process.find_executable("bash") ? "bash" : "sh"
    end

    def run(cmd : String) : {Int32, String}
      output = IO::Memory.new
      status = Process.run(LocalRunner.shell, ["-lc", cmd], output: output, error: output)
      {status.exit_code, output.to_s}
    end

    # Nothing to ship: local "upload" is a copy, and copying a file onto itself
    # is both pointless and destructive (File.copy truncates the source first),
    # so identical paths are a no-op rather than a data-losing move.
    def upload(local : String, remote : String) : Bool
      return true if File.expand_path(local) == File.expand_path(remote)
      Dir.mkdir_p(File.dirname(remote))
      File.copy(local, remote)
      true
    rescue ex
      STDERR.puts VoIPAppz::Colors.yellow("could not copy #{local} -> #{remote}: #{ex.message}")
      false
    end

    def label : String
      "this machine"
    end

    def local? : Bool
      true
    end
  end

  # Another box, over ssh. What the `voip` profile needs: a switch is its own
  # machine.
  class SSHRunner < Runner
    getter workdir : String

    def initialize(@host : String, @user : String, @password : String?,
                   @key : String, @port : Int32, @workdir : String = "/opt/va")
    end

    def run(cmd : String) : {Int32, String}
      VoIPAppz::SSH.run(@host, @user, cmd, @password, @key, @port, capture: true)
    end

    # A LOGIN shell on the far side, so docker resolves the way it does for an
    # operator logging in — ssh's default non-login shell can miss
    # /usr/local/bin and fail with "docker: not found" on a box that has it.
    # Only wrapped here, not in `run`: probes pass their own quoting (curl -w
    # '%{http_code}'), which a blanket wrap would mangle.
    def in_project(cmd : String) : {Int32, String}
      run("bash -lc 'cd #{workdir} && #{cmd}'")
    end

    # Two hops on purpose: scp into /tmp, then move into place. The destination
    # is often root-owned while the ssh user is not, and scp cannot sudo.
    def upload(local : String, remote : String) : Bool
      tmp = "/tmp/#{File.basename(local)}"
      code, _ = VoIPAppz::SSH.upload(@host, @user, local, tmp, @password, @key, @port)
      return false unless code == 0
      run("mkdir -p #{File.dirname(remote)} && mv #{tmp} #{remote}")[0] == 0
    end

    def label : String
      "#{@user}@#{@host}:#{@port}"
    end

    def local? : Bool
      false
    end
  end
end
