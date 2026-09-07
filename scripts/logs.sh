#!/bin/sh
# make logs — follow the node's log: kamailio, FreeSWITCH and the node API
# interleaved, because s6 sends all three to the container's stdout.
#
#   make logs            follow from the last 100 lines
#   make logs TAIL=all   from the beginning
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_docker
docker inspect "$NODE" >/dev/null 2>&1 || die "there is no $NODE container here — start it with: make up"
exec docker logs -f --tail "${TAIL:-100}" "$NODE"
