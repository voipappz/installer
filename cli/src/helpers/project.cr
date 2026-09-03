module VoIPAppz
  # Where the compose project lives.
  #
  # Everything used to be resolved against `Dir.current`: COMPOSE_FILE was the
  # bare string "docker-compose.yaml", SecretsHelper::PROJECT_DIR was
  # `Dir.current`, and DispatcherList::HOST_PATH was a relative path. That works
  # in a checkout, where you are standing in the project, and fails on a real
  # node, where you are not.
  #
  # On a deployed node the installer puts the BINARY in /opt/cli/bin and
  # `voipappz deploy` ships the PROJECT to /opt/va. So running `voipappz sbc ingress
  # list` from where the binary lives reported the dispatcher file "missing"
  # when it was present, and every compose command looked for a
  # docker-compose.yaml that was not there — silently acting on nothing rather
  # than saying so.
  #
  # Resolution order, first hit wins:
  #   1. $VA_PROJECT_DIR            — explicit override, for anything unusual
  #   2. the current directory, or the nearest ancestor of it, containing
  #      docker-compose.yaml — so a checkout keeps working from any subdirectory
  #   3. /opt/va                    — where `voipappz deploy` puts it on a node
  #   4. /stack                     — the copy baked into the voip image
  #   5. the current directory      — nothing found; commands report it plainly
  module Project
    extend self

    COMPOSE_FILE = "docker-compose.yaml"

    # Where a deploy installs the project. Not a guess: DeployManifest::FILES
    # maps every shipped file under this prefix.
    NODE_DIR = "/opt/va"

    # Where ci/Dockerfile.stack unpacks the stack repo INSIDE the voip image.
    #
    # The CLI ships in that image and runs there — `docker exec <node> voipappz
    # status` is the in-container path. A `docker exec` lands in FreeSWITCH's
    # directory, which has no compose file in it or above it, and /opt/va does
    # not exist in the image; without this every project-relative path
    # resolved against /usr/local/freeswitch, and `status` died with
    #
    #   /usr/local/freeswitch/config/services.tsv: No such file or directory
    #
    # AFTER NODE_DIR, deliberately: /opt/va is a project a deploy put there and
    # can update, /stack is baked and immutable. On a host with both, the
    # deployed one is the live one.
    IMAGE_DIR = "/stack"

    # The absolute locations tried when the cwd and its ancestors hold no
    # project, IN ORDER. A list rather than two `if`s so a spec can assert the
    # order itself — which is the part a later edit can silently flip, and the
    # part that decides which project a node with both acts on.
    FALLBACK_DIRS = [NODE_DIR, IMAGE_DIR]

    @@cached : String? = nil

    def root : String
      @@cached ||= resolve
    end

    # For specs, and for a command that legitimately changes directory.
    def reset! : Nil
      @@cached = nil
    end

    # Absolute path to a file inside the project.
    def path(*parts : String) : String
      File.join(root, *parts)
    end

    def compose_file : String
      path(COMPOSE_FILE)
    end

    # Did we actually find a project, or are we falling back to the cwd?
    def found? : Bool
      File.exists?(compose_file)
    end

    private def resolve : String
      if override = ENV["VA_PROJECT_DIR"]?
        return override unless override.empty?
      end

      if dir = ascend_for_compose(Dir.current)
        return dir
      end

      FALLBACK_DIRS.each do |dir|
        return dir if File.exists?(File.join(dir, COMPOSE_FILE))
      end

      Dir.current
    end

    # Walk up from `start` looking for the compose file. Stops at the root, so
    # a checkout works from `spec/`, `src/commands/` or anywhere else in it.
    private def ascend_for_compose(start : String) : String?
      dir = File.expand_path(start)
      loop do
        return dir if File.exists?(File.join(dir, COMPOSE_FILE))
        parent = File.dirname(dir)
        return nil if parent == dir
        dir = parent
      end
    end
  end
end
