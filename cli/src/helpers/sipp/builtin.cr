module VoIPAppz::Sipp
  # The example scenarios, compiled INTO the binary.
  #
  # A provisioned host has the binary at /opt/cli/bin/voipappz and the project at
  # /opt/va, put there by different steps — a scenario that lived only as a repo
  # file would be missing exactly where a load test is worth running. `read_file`
  # also means a renamed or deleted scenario fails the BUILD rather than shipping
  # a command that cannot find its own examples.
  #
  # Not the voip node image: `test` is registered {% unless flag?(:node_runtime) %},
  # so that build has no scenario command to carry examples for.
  module Builtin
    SCENARIOS = {
      "call"               => {{ read_file("#{__DIR__}/../../../scenarios/call.yml") }},
      "dtmf"               => {{ read_file("#{__DIR__}/../../../scenarios/dtmf.yml") }},
      "register"           => {{ read_file("#{__DIR__}/../../../scenarios/register.yml") }},
      "load"               => {{ read_file("#{__DIR__}/../../../scenarios/load.yml") }},
      "trunk-offer-check"  => {{ read_file("#{__DIR__}/../../../scenarios/trunk-offer-check.yml") }},
      "ed137-offer"        => {{ read_file("#{__DIR__}/../../../scenarios/ed137-offer.yml") }},
    }

    # The one-line purpose of each, taken from the manifest's own second comment
    # line so the listing cannot drift from the file.
    def self.summary(name : String) : String
      body = SCENARIOS[name]? || return ""
      body.each_line do |line|
        next unless line.starts_with?("# ")
        text = line[2..].strip
        return text unless text.empty?
      end
      ""
    end

    def self.names : Array(String)
      SCENARIOS.keys.to_a
    end
  end
end
