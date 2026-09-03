require "admiral"
require "http/client"
require "json"
require "base64"
require "uri"
require "../helpers/colors"
require "../helpers/docker"
require "../helpers/freeswitch"

module VoIPAppz::Commands
  class Switch < Admiral::Command
    define_help description: "FreeSWITCH operations"
    register_sub_command reloadacl, type: ReloadAcl
    def run; puts help; end

    # `voipappz switch reloadacl` — reload FreeSWITCH's network ACLs via fs_cli.
    # FS fetches acl.conf from the node over mod_xml_curl (built from va.yaml's
    # `acl:` section), so after the ACL source changes this makes FS re-pull and
    # apply it WITHOUT an FS restart. Modeled on `shell`: the ESL password is read
    # live from the container's event_socket.conf.xml (rotates on FS recreate),
    # falling back to VA_FREESWITCH_PASSWORD.
    class ReloadAcl < Admiral::Command
      define_help description: "Reload FreeSWITCH ACLs (fs_cli reloadacl)"
      CONTAINER = "freeswitch"

      def run
        container = VoIPAppz::Docker.local_exec? ? VoIPAppz::Docker::LOCAL :
                    VoIPAppz::Docker.resolve_container(CONTAINER)
        password = VoIPAppz::FreeSwitch.esl_password(container)
        args = VoIPAppz::FreeSwitch.cli_args(password, ["-x", "reloadacl"])
        exit_code, output = VoIPAppz::Docker.exec(container, args)
        if exit_code == 0 && output.includes?("+OK")
          puts VoIPAppz::Colors.green("✓ FreeSWITCH ACLs reloaded") + VoIPAppz::Colors.dim(" — #{output}")
        else
          detail = output.empty? ? "(no output — is FreeSWITCH up?)" : output
          STDERR.puts VoIPAppz::Colors.red("reloadacl failed: #{detail}")
          exit 1
        end
      end
    end

  end
end
