#!/usr/bin/env bash
# Run Packer from a container that has qemu in it, so nothing has to be
# installed on the workstation.
#
#   packer/build.sh init
#   packer/build.sh validate .
#   packer/build.sh build -only='voipappz.qemu.voipappz' .
#
# Plugins live in a NAMED DOCKER VOLUME, not in the container. Without that,
# every invocation is a fresh container and re-downloads ~100MB of plugins from
# releases.hashicorp.com — which is slow enough that `packer init` has been
# observed to time out mid-download and panic.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${PACKER_BUILDER_IMAGE:-voipappz-packer:local}"
PLUGIN_VOLUME="${PACKER_PLUGIN_VOLUME:-voipappz-packer-plugins}"

REPO_ROOT="$(cd "$HERE/.." && pwd)"

# The app, packaged from THIS checkout, for stack_source=local. Always built —
# the template's `file` provisioner cannot be conditional, so the artifact has
# to exist even when bake.sh will ignore it.
#
# `git archive HEAD` rather than a tar of the directory: it takes exactly the
# tracked files, so data/, certs/, .env, backups/ and every other host-generated
# or gitignored path stays out of the image by construction. bin/voipappz is
# gitignored, so it is appended explicitly.
build_stack_tarball() {
  local out="$HERE/build/stack.tar.gz"
  mkdir -p "$HERE/build"

  # The CLI is not built in this repo any more — its source moved to va-crystal
  # (docs/next-cli-boundary.md; the source is in ../installer since 2026-09-03)
  # and `make build` here copies the
  # artifact in. Fail with THAT instruction rather than `shards build`, which
  # would be run from the wrong directory and report a confusing
  # "Missing shard.yml" — the manifest is in ../installer/cli, not in this repo.
  if [ ! -x "$REPO_ROOT/bin/voipappz" ]; then
    echo "!! bin/voipappz not found — the ISO bakes it, so it must exist first:" >&2
    echo "   make build            # compiles ../installer/cli in Docker (no host toolchain needed)" >&2
    exit 1
  fi

  local staging
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN

  git -C "$REPO_ROOT" archive --format=tar HEAD > "$staging/stack.tar"
  mkdir -p "$staging/bin"
  cp "$REPO_ROOT/bin/voipappz" "$staging/bin/voipappz"
  tar -rf "$staging/stack.tar" -C "$staging" bin/voipappz
  # Atomic: two concurrent builds both regenerate this, and a reader must never
  # see a half-written tarball. Same bytes either way, so last writer wins is
  # fine — a torn file is not.
  gzip -c "$staging/stack.tar" > "$out.tmp.$$"
  mv -f "$out.tmp.$$" "$out"

  echo ">> packaged $(du -h "$out" | cut -f1) stack from $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
}

# The registry credential for the bake's `docker pull`. The stack's own images
# (nirlevi/*) are PRIVATE — without this every pull fails with "pull access
# denied ... may require 'docker login'" and the bake stops at the first one.
#
# Reuses the host's existing `docker login` rather than asking for a password,
# so nothing is decoded or retyped. The copy lands in packer/build/ (gitignored)
# and bake.sh removes /root/.docker/config.json from the image before the
# snapshot — a leftover would ship your registry password to every node.
#
# Written unconditionally, as `{}` when the host is not logged in, because the
# file provisioner referencing it cannot be made conditional.
stage_docker_config() {
  local out="$HERE/build/docker-config.json"
  mkdir -p "$HERE/build"
  if [ -f "$HOME/.docker/config.json" ]; then
    install -m 600 "$HOME/.docker/config.json" "$out"
    echo ">> staged host docker credentials for private image pulls"
  else
    echo '{}' > "$out"
    echo ">> no host docker login found — private images will fail to pull"
  fi
}

# Packer refuses to start when a source's output_directory already exists, and
# any interrupted build leaves one behind — so the failure mode is that the run
# AFTER a cancelled run cannot start either, with an error that names a
# directory rather than the cause. Clear the stale ones first.
#
# Scope is deliberately narrow: only this script's own output directories under
# packer/build/, never the finished .vdi files beside them and nothing outside
# packer/. Root-owned leftovers (Packer runs as root in the container) are
# handed back via a container, since the workstation user cannot remove them.
# Scoped to the target being built, derived from -only=. Clearing ALL of them
# would make two concurrent builds destroy each other's in-progress disks —
# and running the iso and cloud targets in parallel is exactly what you want
# when each takes half an hour.
output_dir_for() {
  case "$*" in
    *qemu.installer*)   echo qemu-iso ;;
    *qemu.direct*)      echo qemu-direct ;;
    *qemu.voipappz*)    echo qemu ;;
    *virtualbox-iso*)   echo vdi ;;
    *)                  echo "" ;;   # amazon-ebs writes nothing locally
  esac
}

clear_stale_output() {
  local d
  d="$(output_dir_for "$@")"
  [ -n "$d" ] || return 0
  if [ -e "$HERE/build/$d" ]; then
    echo ">> clearing stale output directory build/$d"
    rm -rf "$HERE/build/$d" 2>/dev/null || \
      docker run --rm -v "$HERE:/w" alpine:3.22 rm -rf "/w/build/$d"
  fi
}

# Move a finished disk out of its output directory and remove the directory.
#
# Packer leaves the artifact where it built it, so a SUCCESSFUL build is
# indistinguishable from an interrupted one as far as the next run is
# concerned — and `packer validate`, which writes nothing at all, then refuses
# to run with "Output directory 'build/qemu' already exists". That reads as a
# configuration error and is not one. Emptying the directory on the way out
# fixes both: validate works, and `clear_stale_output` above can only ever
# delete a genuinely interrupted build.
#
# The artifacts are already versioned (voipappz-node-<version>.qcow2), so
# flattening them into build/ alongside the ISOs collides with nothing.
collect_output() {
  local d
  d="$(output_dir_for "$@")"
  [ -n "$d" ] || return 0
  [ -d "$HERE/build/$d" ] || return 0

  local f moved=0
  for f in "$HERE/build/$d"/*; do
    [ -e "$f" ] || continue
    mv -f "$f" "$HERE/build/$(basename "$f")"
    echo ">> $d artifact → build/$(basename "$f")"
    moved=1
  done
  # rmdir, not rm -rf: if anything is left in there this must fail loudly
  # rather than delete a disk it did not recognise. An `a && b` one-liner would
  # be wrong here — under `set -e` a false first test fails the whole list, and
  # the script would exit 1 instead of reaching `exit "$status"`.
  if [ "$moved" -eq 1 ]; then
    rmdir "$HERE/build/$d" 2>/dev/null || true
  fi
  return 0
}

case "${1:-}" in
  build) clear_stale_output "$@"; build_stack_tarball; stage_docker_config ;;
  # validate still needs the tarball to EXIST (the provisioner references it),
  # but its contents are irrelevant, so do not pay for packaging.
  #
  # It deliberately does NOT clear output directories: validate would then
  # delete the disk of a build running concurrently. It errors instead
  # ("Output directory ... already exists"), which is the safe way round.
  validate)
    mkdir -p "$HERE/build"
    [ -f "$HERE/build/stack.tar.gz" ] || : | gzip > "$HERE/build/stack.tar.gz"
    [ -f "$HERE/build/docker-config.json" ] || echo "{}" > "$HERE/build/docker-config.json"
    # Same reason: the delivery build's `file` provisioner stats its source at
    # VALIDATE time, and that directory is only populated by the staging step of
    # the build itself. An empty one is enough to parse against.
    mkdir -p "$HERE/build/deliver"
    ;;
esac

# Rebuild when the image is missing OR older than its Dockerfile. Without the
# second test, adding a tool to Dockerfile.builder changes nothing until someone
# deletes the image by hand — and the build then fails deep inside a provisioner
# with "rsync: not found", which names the symptom and not the cause.
builder_is_stale() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || return 0
  local built dockerfile
  built=$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null) || return 0
  built=$(date -d "$built" +%s 2>/dev/null) || return 1
  dockerfile=$(stat -c %Y "$HERE/Dockerfile.builder" 2>/dev/null) || return 1
  [ "$dockerfile" -gt "$built" ]
}

if builder_is_stale; then
  echo ">> building $IMAGE"
  docker build -q -f "$HERE/Dockerfile.builder" -t "$IMAGE" "$HERE" >/dev/null
fi

docker volume inspect "$PLUGIN_VOLUME" >/dev/null 2>&1 || docker volume create "$PLUGIN_VOLUME" >/dev/null

# --device /dev/kvm: the qemu source needs hardware acceleration. Without it
# the build still runs but under TCG emulation, which turns a ~10 minute bake
# into an hour or more.
KVM_ARGS=()
if [ -e /dev/kvm ]; then
  KVM_ARGS=(--device /dev/kvm)
else
  echo ">> WARNING: no /dev/kvm — a qemu build will fall back to slow emulation" >&2
fi

# A directory holding an already-downloaded ISO, mounted READ-ONLY at /iso for
# the qemu.installer source. Read-only is deliberate: this is usually someone's
# Downloads folder and the build has no business writing to it.
#
#   VOIPAPPZ_ISO_DIR=/mnt/c/Users/<you>/Downloads packer/build.sh build \
#     -only='voipappz.qemu.installer' .
ISO_ARGS=()
if [ -n "${VOIPAPPZ_ISO_DIR:-}" ]; then
  ISO_ARGS=(-v "${VOIPAPPZ_ISO_DIR}:/iso:ro")
fi

# SSH material for the delivery provisioner (deliver_host). Read-only, and the
# agent socket too when there is one — a passphrase-protected key is otherwise
# unusable from inside a container that has no terminal to prompt on.
SSH_ARGS=()
if [ -d "$HOME/.ssh" ]; then
  SSH_ARGS=(-v "$HOME/.ssh:/root/.ssh:ro")
fi
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
  SSH_ARGS+=(-v "${SSH_AUTH_SOCK}:/ssh-agent" -e "SSH_AUTH_SOCK=/ssh-agent")
fi

# AWS credentials, if present, for the amazon-ebs source. Mounted read-only;
# env vars win if both are set.
AWS_ARGS=()
[ -d "$HOME/.aws" ] && AWS_ARGS=(-v "$HOME/.aws:/root/.aws:ro")
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_REGION; do
  [ -n "${!v:-}" ] && AWS_ARGS+=(-e "$v")
done

# -t only when there is a terminal: `make image-*` and CI both run this
# without one, and `docker run -t` fails outright there.
TTY_ARGS=()
[ -t 0 ] && [ -t 1 ] && TTY_ARGS=(-it)

# The host's docker socket, for os-image.pkr.hcl. Its shell-local provisioners
# drive containers of their own (apt in a noble image, xorriso, the chown-back),
# and Packer is running inside a container here — so they need a daemon to talk
# to. Docker-out-of-docker: the CLI is in this image, the daemon stays the
# host's. Nothing is nested.
#
# HOST_PACKER_DIR travels with it because a bind mount is resolved by the DAEMON,
# on the host. A path like /w/build/payload means nothing there; the scripts
# translate back to $HERE/build/payload before handing anything to `docker -v`.
# Without it the mounts silently resolve to empty directories the daemon
# creates, and the build produces an ISO with no payload in it.
DOCKER_ARGS=()
if [ -S /var/run/docker.sock ]; then
  DOCKER_ARGS=(-v /var/run/docker.sock:/var/run/docker.sock -e "HOST_PACKER_DIR=$HERE")
  # VA_VOIP_IMAGE so a locally built node image can be baked, and
  # VOIPAPPZ_LOCAL_IMAGES so stage-payload.sh uses it instead of pulling over
  # it. Without forwarding, the build inside the container silently reverts to
  # the published tag and the disc carries something other than what was asked
  # for.
  for v in VA_VOIP_IMAGE VOIPAPPZ_LOCAL_IMAGES; do
    [ -n "${!v:-}" ] && DOCKER_ARGS+=(-e "$v=${!v}")
  done
fi


status=0
docker run --rm "${TTY_ARGS[@]}" \
  "${KVM_ARGS[@]}" \
  "${ISO_ARGS[@]}" \
  "${AWS_ARGS[@]}" \
  "${SSH_ARGS[@]}" \
  "${DOCKER_ARGS[@]}" \
  -v "$HERE:/w" \
  -v "$PLUGIN_VOLUME:/root/.config/packer/plugins" \
  -w /w \
  "$IMAGE" "$@" || status=$?

# Deliver the OS ISO somewhere off the repo, from the HOST.
#
# UNSET BY DEFAULT: the ISO stays in packer/build/iso/ and nothing is copied.
# This used to default to a Windows path under one developer's home directory,
# which is not a default a public repository can carry.
#
# When it IS set, the copy is deliberately not made from inside the container,
# and /mnt/c is deliberately not bind-mounted into it: a container writing a
# multi-GB file onto WSL's 9p mount fails with "cp: write error: I/O error"
# partway through. The same copy from the host works fine, so the artifact is
# written to packer/build/iso/ by the build and moved afterwards.
ISO_DEST="${VOIPAPPZ_ISO_DEST:-}"
# `build` only. Gated because `validate` also reaches here, and it would then
# ship whatever stale ISO happened to be sitting in build/iso — an artifact from
# a previous, possibly different, configuration.
# ...and NOT for the delivery build, which sends the ISO to a REMOTE host and
# has no business also copying it to the local destination. Without this test a
# `-only=voipappz-deliver...` run pushes whatever is in build/iso/ onto
# ISO_DEST as a side effect — which is how a throwaway test artifact ended up
# on the Windows side during exactly that run.
delivery_only() { case "$*" in *voipappz-deliver*) return 0 ;; *) return 1 ;; esac; }

if [ "${1:-}" = "build" ] && [ "$status" -eq 0 ] && [ -d "$ISO_DEST" ] && ! delivery_only "$@"; then
  for iso in "$HERE"/build/iso/voipappz-os-*.iso; do
    [ -e "$iso" ] || continue
    [ -e "$ISO_DEST/$(basename "$iso")" ] && continue
    echo ">> delivering $(basename "$iso") to $ISO_DEST (9p — this takes a while)"
    # The `&&` matters and the failure branch matters more: a full destination
    # leaves a TRUNCATED .tmp behind, and reporting "delivered" over the top of
    # that is worse than not copying at all — the next thing to look at the
    # directory sees a plausible-looking artifact that is not a bootable ISO.
    if cp "$iso" "$ISO_DEST/$(basename "$iso").tmp"; then
      mv -f "$ISO_DEST/$(basename "$iso").tmp" "$ISO_DEST/$(basename "$iso")"
      echo ">> delivered $ISO_DEST/$(basename "$iso")"
    else
      rm -f "$ISO_DEST/$(basename "$iso").tmp"
      echo "!! could not deliver to $ISO_DEST — $(df -h "$ISO_DEST" | awk 'NR==2 {print $4}') free" >&2
      echo "   the ISO is at $iso" >&2
      status=1
    fi
  done
fi

# Packer runs as root in the container, so every artifact it writes into build/
# lands root-owned on the host — and the next run then cannot even create
# build/stack.tar.gz ("Permission denied"). Hand them back. Done in a container
# because the workstation user cannot chown root-owned files without sudo,
# which is precisely the trap this avoids.
if [ -d "$HERE/build" ]; then
  docker run --rm -v "$HERE:/w" alpine:3.22 \
    sh -c "chown -R $(id -u):$(id -g) /w/build" 2>/dev/null || true
fi

# AFTER the chown, not before: the output directory was created by root, and
# moving a file out of a directory needs write permission on the DIRECTORY.
if [ "${1:-}" = "build" ] && [ "$status" -eq 0 ]; then
  collect_output "$@"
fi

exit "$status"
