#!/bin/sh
# MOVED FROM mothership/packer/build.sh and trimmed to the node case.
# Removed: the qemu/VirtualBox/amazon sources and everything that served them —
# --device /dev/kvm, VOIPAPPZ_ISO_DIR, the SSH and AWS mounts for the delivery
# and amazon-ebs builds, build_stack_tarball, stage_docker_config, and
# clear_stale_output/collect_output (a `null` source has no output_directory, so
# there is no stale directory to clear and no artifact to move out of one).
# Kept: the builder image and its staleness check, the plugin volume, the TTY
# guard, the docker-out-of-docker socket and HOST_PACKER_DIR — the details that
# were learned the hard way and still apply.
#
# Run Packer from a container that has the toolchain in it, so nothing has to be
# installed on the workstation.
#
#   packer/build.sh fmt
#   packer/build.sh validate -var image_version=2026.08.27-2 -var release_version=2026.08.27-1
#   packer/build.sh build    -var image_version=2026.08.27-2 -var release_version=2026.08.27-1
#
# A host `packer` is used when there is one. Otherwise the build runs in
# Dockerfile.builder's image, which carries packer, xorriso and a docker client.
# `build` additionally needs a Docker daemon either way — the payload is pulled
# and saved through it.
#
# Plugins live in a NAMED DOCKER VOLUME, not in the container. Without that,
# every invocation is a fresh container and re-downloads the plugins from
# releases.hashicorp.com — slow enough that `packer init` has been observed to
# time out mid-download and panic. (This template needs no plugin: its `null`
# source is built into Packer core. The volume costs nothing and stays because
# adding a source that does need one must not reintroduce that failure.)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="${PACKER_BUILDER_IMAGE:-voipappz-node-packer:local}"
PLUGIN_VOLUME="${PACKER_PLUGIN_VOLUME:-voipappz-node-packer-plugins}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }

[ $# -gt 0 ] || die "usage: $0 <fmt|validate|build> [packer arguments]"
CMD=$1
shift

case "$CMD" in
  fmt|validate|build) ;;
  *) die "unknown command: $CMD (fmt|validate|build)" ;;
esac

if [ "$CMD" = "build" ]; then
  docker info >/dev/null 2>&1 \
    || die "cannot talk to the Docker daemon — the payload is pulled and saved through it"
fi

# ---------------------------------------------------------------- host packer

if command -v packer >/dev/null 2>&1; then
  if [ "$CMD" = "build" ]; then
    command -v xorriso >/dev/null 2>&1 \
      || die "xorriso is not installed — sudo apt-get install -y xorriso"
  fi
  cd "$HERE"
  exec packer "$CMD" "$@" .
fi

# ---------------------------------------------------------------- container
#
# Rebuild the image when it is missing OR older than its Dockerfile. Without the
# second test, adding a tool to Dockerfile.builder changes nothing until someone
# deletes the image by hand — and the build then fails deep inside a provisioner
# with "xorriso: not found", which names the symptom and not the cause.
builder_is_stale() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || return 0
  _built="$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null)" || return 0
  _built="$(date -d "$_built" +%s 2>/dev/null)" || return 1
  _dockerfile="$(stat -c %Y "$HERE/Dockerfile.builder" 2>/dev/null)" || return 1
  [ "$_dockerfile" -gt "$_built" ]
}

if builder_is_stale; then
  printf '>> building %s\n' "$IMAGE"
  docker build -q -f "$HERE/Dockerfile.builder" -t "$IMAGE" "$HERE" >/dev/null
fi

docker volume inspect "$PLUGIN_VOLUME" >/dev/null 2>&1 \
  || docker volume create "$PLUGIN_VOLUME" >/dev/null

# THE WHOLE REPOSITORY is mounted, not just packer/. The mothership's version
# mounted packer/ alone, and that is exactly why its stage-payload.sh had to
# special-case "$REPO_ROOT resolves to / inside the container": the checkout was
# not reachable. Here make-node-iso.sh needs install.sh and the .git directory
# for the identity stamp, so the mount starts at the repository root and the
# working directory is packer/ inside it.
#
# `set --` rather than an array: this script is POSIX sh, like install.sh, and
# the positional parameters are the only portable argument list.
#
# There are TWO lists to assemble — docker's arguments and packer's — and one
# set of positional parameters to hold them. The packer arguments are already
# in "$@", so the docker arguments are APPENDED after them and the list is
# rotated left at the end, which puts them back in the right order without
# quoting anything into a string. Count them before appending anything.
PACKER_ARGC=$#
set -- "$@" --rm -v "$REPO_ROOT:/repo" -v "$PLUGIN_VOLUME:/root/.config/packer" -w /repo/packer

# git in the container runs as root over a checkout owned by someone else, and
# refuses it as "dubious ownership" — which make-node-iso.sh reads as "no
# repository" and stamps the disc `installer commit = unknown`. A disc nobody
# can trace back to a commit is the one thing the identity stamp exists to
# prevent, and the failure is silent. GIT_CONFIG_* rather than a `git config`
# call: it needs no writable HOME and leaves nothing behind.
set -- "$@" -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo

# -t only when there is a terminal: `make iso` and CI both run this without one,
# and `docker run -t` fails outright there.
if [ -t 0 ] && [ -t 1 ]; then
  set -- "$@" -it
fi

# The host's docker socket. node-iso.pkr.hcl's shell-local provisioners drive
# containers of their own (apt in a noble image, the chown-back) and pull and
# save the node image, and Packer is running inside a container here — so they
# need a daemon to talk to. Docker-out-of-docker: the CLI is in this image, the
# daemon stays the host's. Nothing is nested.
#
# HOST_PACKER_DIR travels with it because a bind mount is resolved by the
# DAEMON, on the host. A path like /repo/packer/build/payload means nothing
# there; stage-payload.sh translates back to the host path before handing
# anything to `docker run -v`. Without it the mounts silently resolve to empty
# directories the daemon creates, and the build produces an ISO with no payload
# in it.
if [ -S /var/run/docker.sock ]; then
  set -- "$@" -v /var/run/docker.sock:/var/run/docker.sock -e "HOST_PACKER_DIR=$HERE"
elif [ "$CMD" = "build" ]; then
  die "no /var/run/docker.sock to forward — the containerised build cannot pull or save the node image"
fi

# The registry credential for the private node image, read-only. Reuses the
# host's existing `docker login` rather than asking for a password, so nothing
# is decoded or retyped and no credential is written anywhere new.
if [ -f "$HOME/.docker/config.json" ]; then
  set -- "$@" -v "$HOME/.docker/config.json:/root/.docker/config.json:ro"
fi

set -- "$@" --entrypoint packer "$IMAGE" "$CMD"

# Rotate the packer arguments off the front and onto the end, so the list reads
# docker-options … --entrypoint packer IMAGE COMMAND packer-arguments.
_i=0
while [ "$_i" -lt "$PACKER_ARGC" ]; do
  _first=$1
  shift
  set -- "$@" "$_first"
  _i=$((_i + 1))
done

status=0
docker run "$@" . || status=$?

# Packer ran as root in the container, so build/ comes back root-owned and the
# workstation user cannot even delete it. Hand ownership back through a
# container — an unprivileged user cannot chown what root wrote.
if [ -d "$HERE/build" ]; then
  docker run --rm -v "$HERE/build:/b" --entrypoint chown "$IMAGE" \
    -R "$(id -u):$(id -g)" /b >/dev/null 2>&1 || true
fi

exit "$status"
