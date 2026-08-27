#!/bin/sh
# MOVED FROM mothership/packer/scripts/stage-payload.sh and trimmed to the node
# case. Removed: stage_stack (the mothership's `git archive` of its own
# checkout plus bin/voipappz — this disc ships install.sh instead, and the CLI
# lives inside the node image), compose_images and scripts/compose-images.sh
# (the seventeen-image manifest of the app plane), the split into 2000MB parts
# (that existed because the app payload is 4.6GB; one node image is not, and
# install.sh's `docker load` has no path for reassembling parts), and the
# digest-comparison save cache (one image, and the tag is pinned, so there is
# nothing to compare against).
# Kept, because they were learned the hard way: the apt closure resolved with
# `apt-cache depends --recurse` rather than `apt-get install -d`, the local
# repository with a real Packages index rather than a pile of .debs, the
# offline smoke test, the pull retry loop, the ownership hand-back, and the
# HOST_PACKER_DIR bind-mount translation.
#
# WHAT REPLACED THE PROFILE SCOPING. The original selected images with
# VOIPAPPZ_IMAGE_PROFILES, whose own comment reads "`voip` is one container,
# `app` is the other 15". This repository only ever installs that one
# container, so the `app` branch is not a branch here — it is dead code with no
# manifest behind it. The scope is therefore the single pinned NODE_IMAGE, and
# the mechanism it replaces is named here so a reader can find the original.
#
# Stage the offline payload that packer/make-node-iso.sh bakes into the node
# ISO. Runs against the host Docker daemon — the image has to be pulled
# somewhere, and pulling it here reuses the caller's existing `docker login`
# instead of shipping a registry credential onto the disc.
#
#   packer/scripts/stage-payload.sh debs     # the apt closure, as a repository
#   packer/scripts/stage-payload.sh image    # the one node image
#   packer/scripts/stage-payload.sh all
#
# Output (packer/build/payload/):
#   node-image.tar.gz         `docker save` of ONE image, gzipped
#   node-image.tar.gz.sha256  its checksum, verified on the node before loading
#   node-image.list           what went in, with its resolved digest
#   debs/*.deb + Packages.gz  a real local apt repository
#
# ONE image. The mothership's equivalent stages seventeen, because it installs
# a platform; this installs one VoIP node, which is one container (CLAUDE.md,
# "Runtime contract"). Nothing here knows what a Postgres or a Kong is.
#
# No credential is ever echoed: the login is the caller's, `docker pull` prints
# nothing sensitive, and this script never runs `set -x`.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"       # packer/
OUT="$HERE/build/payload"

log() { printf '>> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

# Bind mounts are resolved by the DAEMON, on the host. When this script runs
# inside the packer builder container (node-iso.pkr.hcl's shell-local
# provisioners, with build.sh's containerised path) our own paths are container
# paths that mean nothing there — the daemon would silently create empty
# directories at them and the build would produce an ISO with no payload in it.
# build.sh passes HOST_PACKER_DIR so we can translate back before handing
# anything to `docker run -v`.
#
# ABSOLUTE only. `docker run -v` treats anything that does not start with / as a
# NAMED VOLUME, not a bind mount — so a relative path silently mounts a fresh
# empty volume instead of the directory you meant, and the failure surfaces much
# later as a tool reading an empty file.
HOST_HERE="${HOST_PACKER_DIR:-$HERE}"
hostpath() {
  case "$1" in
    "$HERE"/*) printf '%s%s' "$HOST_HERE" "${1#"$HERE"}" ;;
    /*)        printf '%s' "$1" ;;
    *)         die "hostpath needs an absolute path: $1" ;;
  esac
}

# The pinned image. node-iso.pkr.hcl passes it; a hand run must name it.
NODE_IMAGE="${NODE_IMAGE:-}"
case "$NODE_IMAGE" in
  '') die "NODE_IMAGE is not set — run this through packer/build.sh, or export NODE_IMAGE=nirlevi/va-crystal:node-<version>" ;;
  *:latest) die "NODE_IMAGE must be a pinned tag, never :latest — media must install the same thing next year" ;;
  *:*) ;;
  *) die "NODE_IMAGE must carry an explicit tag: $NODE_IMAGE" ;;
esac

# The package list. The single source of truth is packer/os-packages.txt;
# node-iso.pkr.hcl reads the same file and passes the result through, so the
# closure downloaded here and the closure the autoinstall installs are one list.
if [ -z "${OS_PACKAGES:-}" ]; then
  [ -f "$HERE/os-packages.txt" ] || die "no OS_PACKAGES and no $HERE/os-packages.txt"
  OS_PACKAGES="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$HERE/os-packages.txt" | grep -v '^$' | tr '\n' ' ')"
fi
[ -n "$OS_PACKAGES" ] || die "the package list is empty"
export OS_PACKAGES

mkdir -p "$OUT/debs"

# ---------------------------------------------------------------- image
#
# `docker save` of the ONE image, gzipped. Written to a .tmp and moved into
# place only after gzip is happy, so an interrupted run cannot leave a truncated
# archive that looks finished — a torn archive is discovered by the operator, on
# the node, with the disc already burned.
stage_image() {
  _pull=1
  if [ "${VA_LOCAL_IMAGE:-0}" = "1" ] && docker image inspect "$NODE_IMAGE" >/dev/null 2>&1; then
    log "$NODE_IMAGE is already local and VA_LOCAL_IMAGE=1 — not pulling"
    _pull=0
  fi
  if [ "$_pull" = "1" ]; then
    # timeout + retry: a stalled pull does not fail, it hangs, and on a flaky
    # link that is the common case.
    _ok=0
    for _attempt in 1 2 3; do
      log "pull $NODE_IMAGE (attempt $_attempt)"
      if timeout 1800 docker pull -q "$NODE_IMAGE" >/dev/null; then _ok=1; break; fi
      printf '   ... stalled or failed, retrying\n' >&2
      sleep 5
    done
    [ "$_ok" = "1" ] || die "could not pull $NODE_IMAGE"
  fi

  # Before anything is archived: an image that cannot exec must not reach a
  # disc. `docker load` proves an image unpacked, not that anything in it can
  # run — a wrong-arch binary or a truncated layer only shows up at exec time,
  # which on an offline node is hours after the media was written.
  #
  # --network none is the point: that is the environment this node has.
  _smoke="$(timeout 120 docker run --rm --network none --entrypoint "" "$NODE_IMAGE" true 2>&1 || true)"
  case "$_smoke" in
    *"exec format error"*|*"no such file or directory"*|*"cannot execute"*)
      die "$NODE_IMAGE cannot execute offline: $(printf '%s' "$_smoke" | tail -1 | cut -c1-70)" ;;
  esac
  log "$NODE_IMAGE executes with no network"

  _digest="$(docker image inspect "$NODE_IMAGE" \
    --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null | sed 's/.*@//')"
  _id="$(docker image inspect "$NODE_IMAGE" --format '{{.Id}}' 2>/dev/null || printf '')"

  # A pipeline's exit status in POSIX sh is the LAST command's, so a `docker
  # save` that dies mid-stream is invisible behind a happy gzip. The status file
  # is how the left-hand side reports; there is no `pipefail` in dash.
  _status="$OUT/.save-status"
  rm -f "$_status"
  log "saving $NODE_IMAGE (this is the slow part)"
  { docker save "$NODE_IMAGE" || printf '%s\n' "$?" > "$_status"; } | gzip -1 > "$OUT/node-image.tar.gz.tmp"
  if [ -f "$_status" ]; then
    rm -f "$_status" "$OUT/node-image.tar.gz.tmp"
    die "docker save $NODE_IMAGE failed"
  fi
  gzip -t "$OUT/node-image.tar.gz.tmp" || die "the saved archive is not readable gzip"
  mv -f "$OUT/node-image.tar.gz.tmp" "$OUT/node-image.tar.gz"

  # The checksum travels with the archive all the way onto the node, where
  # va-node-install verifies it before handing the file to install.sh. A disc
  # that rotted, or a copy that ran out of room during the install, is then a
  # named failure instead of an obscure `docker load` error.
  ( cd "$OUT" && sha256sum node-image.tar.gz > node-image.tar.gz.sha256 )

  # What actually got frozen. The tag alone answers nothing a year from now;
  # this file is copied to /etc/va-crystal-node-image on the node and is the
  # answer to "what is on this machine".
  {
    printf 'image=%s\n' "$NODE_IMAGE"
    printf 'digest=%s\n' "${_digest:-<none>}"
    printf 'id=%s\n' "${_id:-<none>}"
    printf 'saved=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$OUT/node-image.list"

  log "node-image.tar.gz $(du -h "$OUT/node-image.tar.gz" | cut -f1) — ${_digest:-no digest}"
}

# ---------------------------------------------------------------- debs
#
# install.sh runs get.docker.com, which needs network. An offline disc cannot,
# so the same packages are downloaded here instead — as a self-contained local
# apt REPOSITORY, not a pile of .debs. Both halves are load-bearing:
#
#   * `apt-get install -d` resolves against the BUILDER CONTAINER's installed
#     set, so every dependency the container already had is silently skipped and
#     the target dies with unmet dependencies. `apt-cache depends --recurse`
#     asks what docker-ce needs in the abstract, which is the question that
#     matters when the target is a different machine.
#   * `dpkg -i *.deb` cannot satisfy pre-depends ordering, and its usual repair
#     `apt-get -f install` has nothing to reach for offline. A real repository
#     lets apt order the unpacking itself and install only what is missing.
stage_debs() {
  log "downloading the closure of $(printf '%s' "$OS_PACKAGES" | wc -w) packages for an offline install"
  _ok=0
  for _attempt in 1 2 3 4 5; do
    log "  apt attempt $_attempt"
    # Retried because archive.ubuntu.com hands out 403s and resets connections
    # under load. apt only fetches what is missing from the cache directory, so
    # a retry resumes rather than restarts.
    if docker run --rm -e OS_PACKAGES -v "$(hostpath "$OUT/debs"):/out" ubuntu:24.04 bash -c '
      set -eu
      export DEBIAN_FRONTEND=noninteractive
      APTOPT="-o Acquire::Retries=10 -o Acquire::http::Timeout=30 -o Acquire::ForceIPv4=true"
      apt-get $APTOPT update -qq
      apt-get $APTOPT install -y -qq ca-certificates curl >/dev/null
      # HTTPS for the Ubuntu archive once ca-certificates is in: plain HTTP
      # serves most of the pool and then 403s a couple of files consistently
      # across mirror IPs. Over TLS the same URLs fetch normally. After the
      # first update, because switching before ca-certificates exists breaks
      # apt outright.
      sed -i "s|http://archive.ubuntu.com|https://archive.ubuntu.com|g; s|http://security.ubuntu.com|https://security.ubuntu.com|g" \
        /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
      sed -i "s|http://archive.ubuntu.com|https://archive.ubuntu.com|g; s|http://security.ubuntu.com|https://security.ubuntu.com|g" \
        /etc/apt/sources.list 2>/dev/null || true
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get $APTOPT update -qq
      apt-get $APTOPT install -y -qq apt-utils >/dev/null

      # The full recursive closure, asked of the archive rather than of this
      # container. --no-recommends keeps it to what is genuinely required; the
      # other --no-* flags stop apt-cache walking relationships that are not
      # dependencies and dragging in half of main.
      DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests \
               --no-conflicts --no-breaks --no-replaces --no-enhances $OS_PACKAGES \
             | grep "^[a-zA-Z0-9]" | sed "s/:i386$//" | sort -u)

      cd /out
      cached=0
      # One at a time: `apt-get download` fails the WHOLE batch if any single
      # name is a virtual package with no candidate, and the closure always has
      # a few. Skipping them individually is correct — a virtual package has no
      # file to fetch and its providers are already in the list.
      for p in $DEPS; do
        # apt names files <package>_<version>_<arch>.deb, so the name plus an
        # underscore is the prefix to test. The trailing underscore matters:
        # a bare prefix makes docker-ce match docker-ce-cli.
        if ls "${p}"_*.deb >/dev/null 2>&1; then cached=$((cached + 1)); continue; fi
        apt-get $APTOPT download "$p" 2>/dev/null || echo "   (skip virtual/unavailable: $p)"
      done
      # `if`, not `[ ] && echo`: under `set -e` an AND-list whose left side is
      # false fails the whole statement and would exit right here, before the
      # index below is written — the directory then is not a repository at all.
      if [ "$cached" -gt 0 ]; then
        echo "   reused $cached cached .deb (delete packer/build/payload/debs to force a refetch)"
      fi

      # The index IS the repository — without it apt cannot read the directory
      # as a source at all. Rebuilt every run even when nothing was downloaded,
      # because it has to describe exactly what is in the directory now.
      apt-ftparchive packages . > Packages
      gzip -9c Packages > Packages.gz
      ls *.deb | wc -l
    '; then _ok=1; break; fi
    printf '   ... apt run failed, retrying\n' >&2
    sleep 10
  done
  [ "$_ok" = "1" ] || die "could not download the package closure"

  # apt ran as root in the container, so debs/ comes back root-owned and an
  # unprivileged user cannot even list it. Hand ownership back through a
  # container — you cannot chown what root wrote.
  docker run --rm -v "$(hostpath "$OUT"):/p" ubuntu:24.04 chown -R "$(id -u):$(id -g)" /p/debs

  find "$OUT/debs" -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
  rm -f "$OUT/debs/lock"
  [ -s "$OUT/debs/Packages.gz" ] \
    || die "no Packages.gz — the debs directory is not a usable apt repository"
  log "debs: $(find "$OUT/debs" -name '*.deb' | wc -l) packages, $(du -sh "$OUT/debs" | cut -f1) (local apt repo)"
}

case "${1:-all}" in
  image) stage_image ;;
  debs)  stage_debs ;;
  all)   stage_debs; stage_image ;;
  *) die "usage: $0 [all|image|debs]" ;;
esac

log "payload staged in $OUT"
du -sh "$OUT"/* 2>/dev/null || true
