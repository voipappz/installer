#!/bin/sh
# make cli ARGS="..." — the in-image CLI, against the running node.
#
#   make cli ARGS="sbc egress status"
#   make cli ARGS="--help"
#
# The one production CLI lives inside the image and owns every node operation:
# kamailio, FreeSWITCH, health, SIP. There is no host copy to drift from it,
# and this adds nothing to what you type — the arguments go through as given.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_docker
require_running
[ "$#" -gt 0 ] || die 'nothing to run — try: make cli ARGS="sbc egress status"'

if [ -t 0 ]; then
  exec docker exec -it "$NODE" voipappz "$@"
else
  exec docker exec "$NODE" voipappz "$@"
fi
