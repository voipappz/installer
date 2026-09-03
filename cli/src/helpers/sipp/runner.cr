require "digest/sha256"
require "./scenario"

# Executes a compiled scenario through SIPp.
#
# The argument assembly is a port of sippy_cup's Runner (MIT, Mojo Lingo LLC).
# How SIPp is reached is ours, and it is the shape scripts/test-ingress.sh
# already uses for sipexer: a pinned release binary, checksum-verified, cached
# under .cache. SIPp's releases carry a STATICALLY linked `sipp` built with pcap
# support (`sipp -v` reports v3.7.7-PCAP), so there is nothing to compile, no
# libraries to install and no container to run it in.
#
# Executing the binary is all this does. SIPp is GPL-2; a separate process is
# not linking, exactly as helpers/sip.cr records for sipexer.
module VoIPAppz::Sipp
  module Runner
    extend self

    # PINNED, not `latest`: a test whose tool changes under it is a test whose
    # failures cannot be reproduced.
    SIPP_VERSION = "v3.7.7"
    SIPP_SHA256  = "8e8ecdbe923bf608c844038adfa35c8595400c4629d629f00d51539ac24cdfef"
    SIPP_URL     = "https://github.com/SIPp/sipp/releases/download/#{SIPP_VERSION}/sipp"
    CACHE_PATH   = ".cache/sipp"

    # SIPp's documented exit codes. nil means the run succeeded outright.
    def exit_message(code : Int32) : String?
      case code
      when   0 then nil
      when   1 then "at least one call failed"
      when  97 then "SIPp exited on an internal command"
      when  99 then "SIPp processed no calls at all"
      when 254 then "SIPp could not bind its socket — is another SIPp running, or the port privileged?"
      when 255 then "SIPp hit a fatal error"
      else          "SIPp exited #{code}"
      end
    end

    # A failed call is a test result, not a broken run: SIPp says so with 1, and
    # the caller reports it without the machinery having gone wrong.
    def calls_failed?(code : Int32) : Bool
      code == 1
    end

    # An installed SIPp always wins — someone who put one there meant it.
    def local_sipp : String?
      Process.find_executable "sipp"
    end

    def cache_path(project_dir : String) : String
      File.join(project_dir, CACHE_PATH)
    end

    def cached_sipp(project_dir : String) : String?
      path = cache_path(project_dir)
      File.exists?(path) && File::Info.executable?(path) ? path : nil
    end

    # Fetches the pinned release binary and refuses anything that is not it.
    # A load generator aimed at production is not something to take on trust
    # from a redirect, so the checksum is a constant here rather than a second
    # file fetched from the same server.
    def fetch!(project_dir : String) : String
      target = cache_path(project_dir)
      Dir.mkdir_p File.dirname(target)
      download = "#{target}.download"

      status = Process.run("curl",
        ["-sfL", "--retry", "3", "--max-time", "300", "-o", download, SIPP_URL],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      unless status.success?
        File.delete? download
        raise Error.new("could not download SIPp #{SIPP_VERSION} from #{SIPP_URL}")
      end

      digest = sha256(download)
      unless digest == SIPP_SHA256
        File.delete? download
        raise Error.new("SIPp #{SIPP_VERSION} checksum mismatch — refusing it (want #{SIPP_SHA256}, got #{digest})")
      end

      File.rename download, target
      File.chmod target, 0o755
      target
    rescue File::NotFoundError
      raise Error.new("fetching SIPp needs curl, and there is none on PATH — install SIPp instead (#{SIPP_URL})")
    end

    private def sha256(path : String) : String
      digest = Digest::SHA256.new
      File.open(path) do |file|
        buffer = Bytes.new(64 * 1024)
        while (read = file.read(buffer)) > 0
          digest.update buffer[0, read]
        end
      end
      digest.final.hexstring
    end

    # The SIPp command line. Pure — spec'd without running anything.
    def sipp_args(options : Options, scenario_path : String,
                  require_destination : Bool = true,
                  interactive : Bool = true) : Array(String)
      destination = options.destination
      if !destination && require_destination
        raise Error.new("the manifest needs a `destination` to run against")
      end

      args = ["-p", options.source_port.to_s, "-sf", scenario_path]

      if value = options.concurrency
        args << "-l" << value.to_s
      end
      if value = options.number_of_calls
        args << "-m" << value.to_s
      end
      if value = options.calls_per_second
        args << "-r" << number(value)
      end
      # [service] in the scenario's URIs is substituted with this.
      if value = options.to_service
        args << "-s" << value
      end
      if value = options.source
        args << "-i" << value
      end
      if value = options.media_port
        args << "-mp" << value.to_s
      end

      # Rate escalation. -no_rate_quit keeps SIPp running once the ceiling is
      # reached instead of ending the test there.
      if value = options.calls_per_second_max
        args << "-no_rate_quit"
        args << "-rate_max" << number(value)
        args << "-rate_increase" << number(options.calls_per_second_incr || 1.0)
        if interval = options.calls_per_second_interval
          args << "-rate_interval" << interval.to_s
        end
      end

      if value = options.stats_file
        args << "-trace_stat" << "-stf" << value
        args << "-fd" << (options.stats_interval || 1).to_s
      end
      if value = options.summary_report_file
        args << "-trace_screen" << "-screen_file" << value
      end
      if value = options.errors_report_file
        args << "-trace_err" << "-error_file" << value
      end
      if value = options.transport_mode
        args << "-t" << value
      end
      if value = options.scenario_variables
        args << "-inf" << value
      end

      options.sipp_options.try &.each do |key, value|
        args << "-#{key}"
        raw = value.raw
        args << raw.to_s unless raw.nil?
      end

      # SIPp draws an ncurses screen and reads the keyboard unless told not to.
      # With no terminal — CI, a pipe, a background run — that is not merely
      # noisy: it dies on a signal, which surfaces as a killed process rather
      # than any test result at all.
      args << "-nostdin" unless interactive

      args << destination if destination
      args
    end

    # SIPp needs root to replay a pcap: it opens a raw socket to source the RTP
    # from the address it negotiated.
    def needs_sudo?(has_media : Bool) : Bool
      has_media && !root?
    end

    # Checked BEFORE handing the run to sudo. Without this, sudo's own exit 1
    # for "a password is required" is indistinguishable from SIPp's exit 1 for
    # "a call failed", and a run that never started reports as a failed test.
    def sudo_available? : Bool
      Process.run("sudo", ["-n", "true"],
        output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    rescue File::NotFoundError
      false
    end

    def root? : Bool
      buf = IO::Memory.new
      Process.run("sh", ["-c", "id -u"], output: buf, error: Process::Redirect::Close)
      buf.to_s.strip == "0"
    end

    private def number(value : Float64) : String
      value == value.round ? value.to_i.to_s : value.to_s
    end
  end
end
