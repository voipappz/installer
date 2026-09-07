#!/bin/sh
# make health — the node's own verdict, from the CLI inside the image.
#
# The CLI is the only thing that knows what a healthy node is, so this asks it
# rather than probing ports from out here. Its exit status is passed through:
# red is red, and half of what it checks is remote (the mothership, the
# broker), so a node that runs fine here can still report red.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_docker
require_running
exec docker exec "$NODE" voipappz health
