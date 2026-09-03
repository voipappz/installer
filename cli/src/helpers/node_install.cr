require "./colors"
require "./env_file"
require "./project"

module VoIPAppz
  # Installing a SEPARATE VoIP node against this mothership.
  #
  # The node is and stays separate: its own container (va-voip), its own
  # directory, its own lifecycle. This only launches the PUBLIC node installer
  # (github.com/voipappz/installer) with answers derived from this checkout —
  # it does not reimplement any part of the install. That installer is a mature
  # project of its own and stays the single implementation; making this a CLI
  # command changes who calls it, not what installs a node.
  #
  # Ported from scripts/install-node.sh so `make node-install` is a CLI wrapper
  # like every other verb. The three properties that script got right and that
  # must not be lost in the port are marked below.
  module NodeInstall
    extend self

    DEFAULT_URL = "https://raw.githubusercontent.com/voipappz/installer/main/install.sh"

    class Failed < Exception; end

    # Where the installer comes from. A LOCAL FILE or a URL — never both, and
    # the caller is always told which, because the difference is whether you
    # just deployed a released installer or the one in your working tree.
    #
    # Order, matching va-crystal's scripts/install-here.sh:
    #   --installer <path>   explicit, wins over everything
    #   $VA_INSTALLER        the same, from the environment
    #   ../installer/install.sh   the sibling clone, when it is there
    #   $VA_INSTALLER_URL / the published one
    #
    # The sibling is preferred on purpose: this repo already resolves siblings
    # that way (the portal at ../app), and someone with the installer checked
    # out beside the mothership is working on it. It is announced every time
    # rather than assumed — deploying an uncommitted installer to a real host
    # should never be something you discover afterwards.
    def sibling_installer : String
      File.join(File.dirname(VoIPAppz::Project.root), "installer", "install.sh")
    end

    # A REGULAR, NON-EMPTY file — not merely something that exists.
    # `File.exists?` accepted /dev/null, and an empty installer runs, exits 0
    # and installs nothing: a silent no-op is the worst possible outcome here,
    # because the deploy reports success against a host with no node on it.
    def installer?(path : String) : Bool
      File.file?(path) && File.size(path) > 0
    end

    # {kind, value} — :path with a local file, :url otherwise.
    def installer_source(override : String = "") : {Symbol, String}
      if !override.empty?
        raise Failed.new("not a usable installer: #{override}") unless installer?(override)
        return {:path, File.expand_path(override)}
      end
      if (env = ENV["VA_INSTALLER"]?.presence)
        raise Failed.new("not a usable installer: #{env} (VA_INSTALLER)") unless installer?(env)
        return {:path, File.expand_path(env)}
      end
      return {:path, sibling_installer} if installer?(sibling_installer)
      {:url, ENV["VA_INSTALLER_URL"]?.presence || DEFAULT_URL}
    end

    def describe(source : {Symbol, String}) : String
      source[0] == :path ? "#{source[1]} (local)" : source[1]
    end

    # Answers derived from the mothership itself; the environment wins over
    # .env, matching how every other CLI value resolves.
    #
    # Credentials deliberately do NOT come from .env in general:
    # src/voipappz.cr refuses to load VA_API_AUTHORIZATION out of a .env at all
    # ("process-only"), and reading it here through a side door would undo that.
    #
    # VA_SECRET_KEY is the ONE exception, and it is not a side door — it is the
    # node's own requirement. The cable server verifies mothership USER tokens
    # against `ENV["SECRET_KEY"]` (va-crystal node/realtime/app.cr:75), and when
    # that is empty it refuses EVERY connection (app.cr:90) — its own log line
    # says so. Without this the node installs, starts, reports healthy, and
    # authenticates nobody: the failure surfaces at each client as a websocket
    # that closes before `welcome`, which is indistinguishable from a dead
    # network. Passing it is what makes the installed node usable at all.
    #
    # The narrower alternative is giving the node its own secret and having the
    # mothership mint cable tokens with it (app.cr:99 already accepts that
    # shape). That keeps the user-token secret in one place and is the better
    # end state; it needs a minting path on the mothership side first.
    def mothership_env : Hash(String, String)
      dotenv = begin
        VoIPAppz::EnvFile.load(File.join(VoIPAppz::Project.root, ".env"), first_wins: true)
      rescue
        {} of String => String
      end

      resolved = {} of String => String
      {"VA_API_URL", "VA_NATS_URL", "VA_SECRET_KEY"}.each do |key|
        value = ENV[key]?.presence || dotenv[key]?.presence
        resolved[key] = value if value
      end
      resolved
    end

    # THE INSTALLER DELETES docker-compose.yaml FROM ITS INSTALL DIRECTORY, and
    # it installs to the same default path the mothership does.
    #
    # install.sh:40 defaults INSTALL_DIR to /opt/voipappz — where the mothership
    # installer also puts a stack — and commit_install_dir (:533-539) removes any
    # docker-compose.yaml it finds there, deliberately: "a stale compose file
    # would start a second, different node beside the one this installer runs".
    # That is right for the compose-era leftovers it was written for, and it
    # cannot tell those from a live stack. So a local `node install` on a
    # mothership box would take that stack's compose file with it and leave
    # `up`, `down` and `status` with nothing to read.
    #
    # Still true with the `voip` profile gone (2026-09-01, 4ec7719bd): this is
    # about two INSTALLERS sharing a directory, not about two ways to start a
    # container.
    DEFAULT_INSTALL_DIR = "/opt/voipappz"

    def install_dir : String
      ENV["INSTALL_DIR"]?.presence || DEFAULT_INSTALL_DIR
    end

    # A mothership lives here if a compose file does. The installer would delete
    # it; say so first and let the operator choose another directory.
    def mothership_dir?(dir : String) : Bool
      File.exists?(File.join(dir, "docker-compose.yaml"))
    end

    def credentialed? : Bool
      !ENV["VA_API_AUTHORIZATION"]?.presence.nil? || !ENV["VA_API_EMAIL"]?.presence.nil?
    end

    # A remote node cannot reach a mothership on the deploy box's loopback.
    # Caught here rather than 20 minutes into an install that then registers
    # nothing and leaves a node pointed at itself.
    def loopback?(values : Hash(String, String)) : Bool
      values.values.any? { |v| v.includes?("127.0.0.1") || v.includes?("localhost") }
    end

    # KEY=VALUE lines for the installer — secrets included. Carried on stdin
    # (local: a file we write 0600; remote: the ssh channel), NEVER on a
    # command line, where `ps` would show them to every user on the box.
    def answer_file(values : Hash(String, String)) : String
      String.build do |io|
        values.each { |k, v| io << k << '=' << v << '\n' }
        # VA_REGISTRY_* is how install.sh takes the image credential without
        # asking (install.sh:1039-1057). Not forwarding it meant an operator
        # with the credential already exported still got prompted for it —
        # halfway through an otherwise unattended install, which is the one
        # place a prompt is useless.
        %w(VA_API_AUTHORIZATION VA_API_EMAIL VA_API_PASSWORD VA_KAMAILIO VA_FREESWITCH
           VA_REGISTRY_USER VA_REGISTRY_TOKEN).each do |key|
          if value = ENV[key]?.presence
            # Quoted: an Authorization header carries spaces, and a password can
            # carry anything at all.
            io << key << "='" << value << "'\n"
          end
        end
        source = ENV["VA_IMAGE_SOURCE"]?.presence || "s3"
        io << "VA_IMAGE_SOURCE=" << source << '\n'
        # VA_IMAGE_ARCHIVE travels with it or `archive` cannot work remotely:
        # install.sh refuses the mode outright without a path, so a remote
        # install died on "VA_IMAGE_SOURCE=archive needs VA_IMAGE_ARCHIVE" while
        # the caller had set both. The path is the TARGET's, not this machine's
        # — a URL, or a file already copied there.
        if archive = ENV["VA_IMAGE_ARCHIVE"]?.presence
          io << "VA_IMAGE_ARCHIVE='" << archive << "'\n"
        end
      end
    end

    # The remote script, run by `sh -s` on the far side. The answer file is
    # written into a private directory with umask 077, used, and removed —
    # whatever the installer's exit code, which is preserved.
    #
    # A LOCAL installer travels the same channel as the answers rather than
    # being fetched by the target: the whole point of pointing at ../installer
    # is to run the one in your tree, and the remote host has no access to it
    # (and may have no route to GitHub at all).
    #
    # Delimiters are chosen not to collide with shell content. The installer is
    # ~1100 lines of POSIX sh containing plenty of quoting; a quoted heredoc
    # marker means the far side interpolates nothing, so it arrives verbatim.
    # The installer's own arguments, as install.sh documents them at :65 —
    # `sh install.sh --no-register`, and over curl `sh -s -- --no-register`.
    # The `-s --` is not decoration: without it sh reads the flag as the name
    # of a script to run and the installer never starts.
    def command(source : {Symbol, String}, args : Array(String)) : String
      flags = args.empty? ? "" : " " + args.join(' ')
      if source[0] == :path
        "sh '#{source[1]}'#{flags}"
      else
        "curl -fsSL '#{source[1]}' | sh#{args.empty? ? "" : " -s --"}#{flags}"
      end
    end

    def remote_script(answers : String, source : {Symbol, String}, args : Array(String) = [] of String) : String
      run =
        if source[0] == :path
          body = File.read(source[1])
          raise Failed.new("#{source[1]} contains the heredoc delimiter") if body.includes?("\nVAINSTALLER_EOF\n")
          flags = args.empty? ? "" : " " + args.join(' ')
          <<-EMBED
          cat > install.sh <<'VAINSTALLER_EOF'
          #{body.rstrip}
          VAINSTALLER_EOF
          sh install.sh#{flags}; rc=$?
          EMBED
        else
          "#{command(source, args)}; rc=$?"
        end

      <<-SH
      mkdir -p ~/.va-node-install && cd ~/.va-node-install && umask 077 && cat > .env <<'VAEOF'
      #{answers.rstrip}
      VAEOF
      #{run}
      rm -f .env install.sh; exit $rc
      SH
    end
  end
end
