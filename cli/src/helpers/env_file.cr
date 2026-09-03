module VoIPAppz
  # Read a `KEY=value` file into a Hash.
  #
  # THIS IS A PARSER, NOT AN INTERPRETER, and that is the point. The Makefile
  # this replaces reached kamal's registry password with
  #
  #     set -a; . .kamal/secrets; set +a
  #
  # which *executes* the file: a `$(…)` or a backtick anywhere in a value runs
  # as a command in the deploy shell, with the deployer's ssh agent and docker
  # socket in reach. Reading the file cannot do that.
  #
  # Two precedence rules exist in the wild and the difference is not cosmetic:
  #
  #   last_wins (default)  what `. file` does — a later line overrides an earlier
  #                        one. Correct for .kamal/secrets and for layering
  #                        secrets-common under secrets.<dest>.
  #   first_wins           what `sed -n 's/^KEY=//p' | head -1` does, which is
  #                        how the portal Makefile read MOTHERSHIP_URL and
  #                        PROD_URL out of .env.
  #
  # Picking one for both silently changes behaviour on a file with a duplicated
  # key, so the caller says which it means.
  module EnvFile
    extend self

    def load(path : String, first_wins : Bool = false) : Hash(String, String)
      result = {} of String => String
      return result unless File.exists?(path) && File::Info.readable?(path)

      File.each_line(path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        # `export KEY=value` is valid in a sourced file, so it is valid here.
        line = line[7..].lstrip if line.starts_with?("export ")

        key, sep, value = line.partition('=')
        # A bare `KEY` with no `=` sets nothing when sourced; skip it rather than
        # inventing an empty value the shell would not have set.
        next if sep.empty?
        key = key.strip
        next if key.empty?
        next if first_wins && result.has_key?(key)

        result[key] = unquote(value.strip)
      end
      result
    end

    # Layer files lowest-precedence first, mirroring how a shell sourcing them
    # in order would end up.
    def layer(paths : Array(String)) : Hash(String, String)
      paths.reduce({} of String => String) { |acc, p| acc.merge(load(p)) }
    end

    # First non-empty value among the keys, in the order given. This is
    # PRECEDENCE, not file order — the portal Makefile needed two separate seds
    # rather than one alternation for exactly this reason: an alternation matches
    # whichever key appears first in the file, so it could resolve to the wrong
    # host and report OK against it.
    def first_set(env : Hash(String, String), keys : Array(String)) : String?
      keys.each do |k|
        v = env[k]?
        return v if v && !v.empty?
      end
      nil
    end

    # Values reach a child process by NAME (`docker run -e KEY`), never as
    # `-e KEY=value`: the latter puts secrets in the process table for any
    # `ps aux` to read.
    def export!(env : Hash(String, String)) : Nil
      env.each { |k, v| ENV[k] = v }
    end

    private def unquote(value : String) : String
      return value if value.size < 2
      if (value.starts_with?('"') && value.ends_with?('"')) ||
         (value.starts_with?('\'') && value.ends_with?('\''))
        value[1..-2]
      else
        value
      end
    end
  end
end
