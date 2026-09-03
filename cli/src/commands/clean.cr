require "admiral"
require "../helpers/docker"
require "../helpers/colors"

module VoIPAppz::Commands
  class Clean < Admiral::Command
    define_help description: "Clean Docker resources"

    define_flag volumes : Bool,
      description: "Also remove unused volumes (DANGEROUS)",
      default: false,
      short: v
    define_flag all : Bool,
      description: "Remove images, volumes, and prune system (DANGEROUS)",
      default: false,
      short: a
    define_flag force : Bool,
      description: "Skip confirmation prompts",
      default: false,
      short: f
    define_flag orphans : Bool,
      description: "Remove containers no longer defined in docker-compose.yaml (keeps running stack up)",
      default: false,
      short: o

    def run
      if flags.all
        clean_all
      elsif flags.volumes
        clean_volumes
      elsif flags.orphans
        clean_orphans
      else
        clean_basic
      end
    end

    # Drop containers that exist locally but aren't in docker-compose.yaml
    # anymore (e.g. after deleting a service). Doesn't recreate or restart
    # anything still defined — `up --no-recreate --remove-orphans` is the
    # idiomatic compose recipe for this.
    private def clean_orphans
      puts VoIPAppz::Colors.bold("Removing orphan containers...")
      VoIPAppz::Docker.compose!(["up", "-d", "--no-recreate", "--remove-orphans"])
      puts VoIPAppz::Colors.green("Orphans removed")
    end

    private def clean_basic
      puts VoIPAppz::Colors.bold("Cleaning up...")

      # Remove temp files
      ["/tmp/sipexer_*.log", "/tmp/health_monitor.*", "/tmp/*.sql"].each do |pattern|
        Dir.glob(pattern).each { |f| File.delete(f) rescue nil }
      end

      # Docker image prune
      puts VoIPAppz::Colors.cyan("  Removing unused Docker images...")
      process = Process.new("docker", ["image", "prune", "-f"],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      process.wait

      puts VoIPAppz::Colors.green("Cleanup completed")
    end

    private def clean_volumes
      unless flags.force
        puts VoIPAppz::Colors.red("WARNING: This will remove unused Docker volumes!")
        print "Continue? (y/N) "
        confirm = gets
        unless confirm && confirm.strip.downcase == "y"
          puts "Cancelled."
          return
        end
      end

      puts VoIPAppz::Colors.bold("Removing unused volumes...")
      process = Process.new("docker", ["volume", "prune", "-f"],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      process.wait

      puts VoIPAppz::Colors.green("Volumes cleaned")
    end

    private def clean_all
      unless flags.force
        puts VoIPAppz::Colors.red("WARNING: This will remove ALL unused images, volumes, and prune the system!")
        print "Continue? (y/N) "
        confirm = gets
        unless confirm && confirm.strip.downcase == "y"
          puts "Cancelled."
          return
        end
      end

      puts VoIPAppz::Colors.bold("Full Docker cleanup...")

      puts VoIPAppz::Colors.cyan("  Removing unused images...")
      Process.new("docker", ["image", "prune", "-f"],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).wait

      puts VoIPAppz::Colors.cyan("  Removing unused volumes...")
      Process.new("docker", ["volume", "prune", "-f"],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).wait

      puts VoIPAppz::Colors.cyan("  Pruning system...")
      Process.new("docker", ["system", "prune", "-f"],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).wait

      puts VoIPAppz::Colors.green("Full cleanup completed")
    end
  end
end
