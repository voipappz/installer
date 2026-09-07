#!/bin/sh
# make down — stop the node, keeping its identity and its kamailio volume.
#
# `docker stop`, not `rm`: the container keeps its name, its mounts and the
# subscribers in the voipappz-kamailio volume, so `make up` brings back the
# same node rather than a new one. Removing it is `make up`'s job, and only
# because starting a node IS replacing it.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_docker
docker inspect "$NODE" >/dev/null 2>&1 || die "there is no $NODE container here"
running || { say "$NODE is already stopped"; exit 0; }

docker stop "$NODE" >/dev/null || die "could not stop $NODE"
say "stopped $NODE (its kamailio volume is untouched)"
