#!/bin/sh
# Which container images does a node carry?
#
#   scripts/node-images.sh          # the node image, as install.sh resolves it
#
# ONE image. That is the whole answer, and it is why this file is four lines of
# logic and sixty of explanation: `nirlevi/va-crystal:node` carries FreeSWITCH,
# the egress kamailio and the node process in a single container, and
# scripts/up.sh starts it with one `docker run` — there is no compose project on
# a node and nothing else to enumerate.
#
# WHY THIS EXISTS AT ALL, rather than the literal being written twice. The ISO
# payload (packer/scripts/stage-payload.sh) and the disk bake
# (packer/scripts/bake.sh) both have to know what to pull, save and load, and
# install.sh has to know what to run. An image in the media but not in the
# installer is a disc that carries something nothing starts; the reverse is an
# air-gapped node with nothing to start at all, and no way to fetch it. So the
# tag is defaulted in exactly one place, install.sh, and both build scripts ask
# here.
#
# WHAT THIS REPLACED. This tooling came from the mothership repo, where the
# equivalent was scripts/compose-images.sh: an awk over a 20-service
# docker-compose.yaml, a profile scope to pick a plane out of it, and two
# assertions that the chosen scope had not silently dropped its own plane's
# image. All of that was machinery for choosing among many images. A node has
# one, so the scope, the awk and the guards are gone — what is left is the one
# thing they were protecting.
#
# POSIX sh: this runs on the workstation, inside the packer builder container,
# and on the baking VM. No bash, no docker, no network.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The default lives in install.sh and is read OUT of it, not copied. A second
# copy of the tag is how media and installer drift: the disc carries :node while
# the installer runs :latest, the node comes up on an image the ISO never
# froze, and on an air-gapped machine that is a node that cannot start.
#
# VA_VOIP_IMAGE from the environment still wins, exactly as it does for
# install.sh — that is how a locally built image gets baked onto a disc.
if [ -z "${VA_VOIP_IMAGE:-}" ]; then
  # shellcheck disable=SC2016  # a sed pattern, not an expansion
  VA_VOIP_IMAGE="$(sed -n 's/^VA_VOIP_IMAGE="\${VA_VOIP_IMAGE:-\([^}]*\)}"$/\1/p' \
    "$ROOT/install.sh" | head -n 1)"
fi

# A floor, for the same reason check-packer-targets.sh has one: if that sed
# stops matching because install.sh was reformatted, every caller would happily
# stage an empty image list and cut a disc with no node on it. Eight minutes
# later there is an 8GB ISO and no error anywhere.
if [ -z "$VA_VOIP_IMAGE" ]; then
  echo "!! could not read VA_VOIP_IMAGE's default out of install.sh — pass VA_VOIP_IMAGE=<image> or fix the extractor here" >&2
  exit 1
fi

# And it must be a resolvable reference, not a leftover shell expansion. The
# mothership's version of this skipped anything still carrying `${` after
# substitution and that is how the entire SIP plane once fell out of a bake
# silently; here there is one image, so the same mistake is one line to refuse.
# shellcheck disable=SC2016  # matching a literal ${, not expanding one
case "$VA_VOIP_IMAGE" in
  *'${'*) echo "!! VA_VOIP_IMAGE is unresolved ($VA_VOIP_IMAGE) — it needs a literal tag to pull" >&2; exit 1 ;;
  */*:*) ;;
  *) echo "!! VA_VOIP_IMAGE does not look like a repository:tag ($VA_VOIP_IMAGE)" >&2; exit 1 ;;
esac

printf '%s\n' "$VA_VOIP_IMAGE"
