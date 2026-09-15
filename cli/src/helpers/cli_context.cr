module VoIPAppz
  # WHICH NODE THIS INVOCATION IS ABOUT, said on the command line.
  #
  #     voipappz -f ./config/va.bridge.yaml --env-file ./.env.bridge sbc egress status
  #
  # One host is about to carry SEVERAL node documents — one per network: a
  # `--network host` node and a bridge node with a pinned address are two
  # different va.yaml files beside two different .env files. Until now the only
  # way to point a command at one of them was to export VA_PATH (and
  # VA_CONFIG_PATH, and VA_ENV_FILE) around it, which is a thing you get wrong
  # once and then debug as "why did that command answer about the other node".
  # It is `docker compose -f`'s problem exactly, so it gets `docker compose
  # -f`'s spelling.
  #
  # BEFORE THE SUB-COMMAND, which is where docker compose takes its own -f and
  # the only place this can be taken: `voipappz logs -f` still means follow,
  # `voipappz -f x logs -f` means both. Parsed here rather than as an Admiral
  # root flag because Admiral dispatches on argv[0] and never runs the root
  # command's `run` when a sub-command is present (command/runner.cr), so a
  # root flag's value would be parsed and then dropped on the floor. The
  # `monitor` rewrite and the negative-number glue in voipappz.cr are here for
  # the same reason.
  #
  # WHAT THEY SET, rather than a new argument threaded through every command:
  # the environment the CLI already resolves through.
  #
  #   -f, --file   VA_PATH + VA_CONFIG_PATH — VaConfig.yaml_path, `sbc`,
  #                `dump`, NodeLocal.yaml_path
  #   --env-file   VA_ENV_FILE — the startup env load and NodeLocal.env, so
  #                the secrets, the service flags and a VA_VOIP_CONTAINER
  #                naming this node's container all come from the file named
  #
  # Both YAML variables, not just VA_PATH: VA_CONFIG_PATH inherited from the
  # environment would otherwise win over the file just named on the command
  # line, and a flag that loses to an export is worse than no flag.
  module CliContext
    extend self

    class Error < Exception; end

    YAML_FLAGS = {"-f", "--file"}
    ENV_FLAGS  = {"--env-file"}

    record Selection, yaml : String? = nil, env_file : String? = nil

    def extract!(argv : Array(String)) : Selection
      selection = parse!(argv)
      apply!(selection)
      selection
    end

    # Consume the leading global options, leaving the sub-command first.
    # Anything that is not one of them ends the scan, so a sub-command's own
    # flags are never touched.
    def parse!(argv : Array(String)) : Selection
      yaml : String? = nil
      env_file : String? = nil

      while (arg = argv.first?)
        name, separator, inline = arg.partition('=')
        break unless YAML_FLAGS.includes?(name) || ENV_FLAGS.includes?(name)
        argv.shift
        value = separator.empty? ? argv.shift? : inline
        raise Error.new("#{name} needs a path") if value.nil? || value.empty?

        if YAML_FLAGS.includes?(name)
          # A node is ONE document. `docker compose -f a -f b` merges, which is
          # meaningful for a stack of services and meaningless for a single
          # node: there is no second half of a va.yaml to overlay. Say so
          # instead of silently acting on one of the two.
          raise Error.new("one node document at a time: #{yaml} and then #{value}") if yaml && yaml != value
          yaml = value
        else
          raise Error.new("one env file at a time: #{env_file} and then #{value}") if env_file && env_file != value
          env_file = value
        end
      end

      Selection.new(yaml, env_file)
    end

    # ABSOLUTE, ALWAYS. These paths are read again after commands have changed
    # directory, handed to `docker run -v`, and printed in messages an operator
    # is meant to be able to retype; a relative one is a different file in each
    # of those places.
    def apply!(selection : Selection) : Nil
      if path = selection.yaml
        absolute = File.expand_path(path)
        # The FILE may be absent — `setup` is told to create one, and pointing
        # it at a new document is half of what this flag is for. Its directory
        # may not be: that is a typo, and the file it would write is not the
        # file the next command reads.
        directory = File.dirname(absolute)
        raise Error.new("no directory #{directory} — -f names this node's va.yaml") unless Dir.exists?(directory)
        ENV["VA_PATH"] = absolute
        ENV["VA_CONFIG_PATH"] = absolute
      end

      if path = selection.env_file
        absolute = File.expand_path(path)
        # Missing IS an error here, unlike the YAML: nothing in the CLI writes
        # a node's .env (install.sh and `make setup` do), and a missing one
        # loads no keys at all — every command that needed a secret from it
        # would fail somewhere further down naming something else.
        raise Error.new("no #{absolute} — --env-file names this node's .env") unless File.exists?(absolute)
        ENV["VA_ENV_FILE"] = absolute
      end
    end
  end
end
