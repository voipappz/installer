require "spec"

# Point every helper that resolves repo files at a FIXTURE project, not at the
# checkout this spec happens to be sitting in.
#
# The catalog and the deploy manifest are data files in the STACK repo
# (config/services.tsv, config/deploy-manifest.tsv). This source is moving to
# va-crystal, which has neither — so a spec that read the real ones passed here
# and failed there, which is the same class of coupling that made the source
# unmovable in the first place (docs/next-cli-boundary.md, M1).
#
# The real files are guarded where they live, by scripts/check-services.sh and
# scripts/check-deploy-manifest.sh, against the compose file they must agree
# with. These specs guard the CODE against a known fixture. Different jobs.
ENV["VA_PROJECT_DIR"] ||= File.expand_path("fixtures/project", __DIR__)

require "../src/helpers/topology"
require "../src/helpers/deploy_config"
