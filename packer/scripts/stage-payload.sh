#!/usr/bin/env bash
# Stage the offline payload that packer/make-installer-iso.sh bakes into the
# ISO. Runs on the WORKSTATION against the host docker daemon — the images have
# to be pulled somewhere, and pulling them here reuses the host's existing
# `docker login` instead of shipping a registry credential into a VM.
#
# Output (packer/build/payload/):
#   images.tar.gz   the node image, docker-saved
#   images.list     what went in, with its resolved digest
#   stack.tar.gz    this checkout (git archive HEAD) + bin/voipappz
#   debs/*.deb      docker-ce and dependencies, for an install with no network
#
# This is the expensive half of the build (~15GB of pulls, then a save), so it
# is a separate script: the ISO can be re-cut from an unchanged payload without
# touching Docker Hub again.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"       # packer/
REPO_ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build/payload"
mkdir -p "$OUT/debs"

log() { echo ">> $*"; }

# Bind mounts are resolved by the DAEMON, on the host. When this script runs
# inside the packer builder container (os-image.pkr.hcl's shell-local
# provisioners) our own paths are container paths that mean nothing there — the
# daemon would silently create empty directories at them and the build would
# produce an artifact with no payload. build.sh passes HOST_PACKER_DIR so we can
# translate back before handing anything to `docker run -v`.
HOST_HERE="${HOST_PACKER_DIR:-$HERE}"
hostpath() { printf '%s' "${1/#$HERE/$HOST_HERE}"; }


# ---------------------------------------------------------------- stack
#
# `git archive HEAD` rather than a tar of the directory, for the same reason
# build.sh does it: it takes exactly the tracked files, so data/, certs/, .env
# and every gitignored path stays out by construction. bin/voipappz is
# gitignored, so it is appended explicitly.
stage_stack() {
  # build.sh already packages this on the HOST, before it launches Packer, and
  # leaves it at build/stack.tar.gz. Reuse it.
  #
  # Not just a cache — a correctness fix. Under Packer this script runs INSIDE
  # the builder container, which mounts only packer/, so $REPO_ROOT resolves to
  # "/" and neither bin/voipappz nor the .git directory `git archive` needs is
  # reachable. The host-built tarball is the same bytes from a context that can
  # actually see the repository.
  if [ -f "$HERE/build/stack.tar.gz" ]; then
    cp -f "$HERE/build/stack.tar.gz" "$OUT/stack.tar.gz"
    log "stack.tar.gz $(du -h "$OUT/stack.tar.gz" | cut -f1) (reused from build.sh)"
    return 0
  fi

  if [ ! -x "$REPO_ROOT/bin/voipappz" ]; then
    echo "!! bin/voipappz not found — build it first: shards build voipappz" >&2
    exit 1
  fi
  local staging; staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN

  # Same exclusions as packer/build.sh: a node runs install.sh, scripts/ and
  # the binary — not the CLI's source, the media tooling or the test suites.
  git -C "$REPO_ROOT" archive --format=tar HEAD -- . \
    ':(exclude)cli' ':(exclude)packer' ':(exclude)tests' ':(exclude)spec' \
    ':(exclude).github' ':(exclude).agents' ':(exclude).codex' ':(exclude)docs' \
    ':(exclude)DEVELOPMENT.md' ':(exclude).actrc' ':(exclude).gitignore' \
    > "$staging/stack.tar"
  mkdir -p "$staging/bin"
  cp "$REPO_ROOT/bin/voipappz" "$staging/bin/voipappz"
  tar -rf "$staging/stack.tar" -C "$staging" bin/voipappz
  gzip -c "$staging/stack.tar" > "$OUT/stack.tar.gz.tmp"
  mv -f "$OUT/stack.tar.gz.tmp" "$OUT/stack.tar.gz"

  log "stack.tar.gz $(du -h "$OUT/stack.tar.gz" | cut -f1) from $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
}

# ---------------------------------------------------------------- images
#
# WHICH images is scripts/node-images.sh — one implementation, shared with
# bake.sh, so the ISO payload and the disk bake cannot disagree about what a
# node carries. It answers with ONE image: the node is a single container.
#
# There is no profile scope here any more. The mothership's version of this
# script chose a plane out of a 20-service compose file, which is what
# VOIPAPPZ_IMAGE_PROFILES existed for; a node has one image, so the scope, and
# the two assertions that guarded against a scope dropping its own plane, are
# gone with it.

# Already-built images are NOT re-pulled when this is set. That is what makes a
# payload from a local `make -C ../va-crystal node-image` possible: the image
# exists nowhere else yet, and a pull would fail (or worse, quietly replace it
# with an older published one).
LOCAL_IMAGES="${VOIPAPPZ_LOCAL_IMAGES:-0}"

node_images() {
  "$REPO_ROOT/scripts/node-images.sh"
}

# ---------------------------------------------------------------- smoke test
#
# Start every image with NO NETWORK and check the entrypoint actually execs.
#
# `docker load` proves an image unpacked; it does not prove anything in it can
# run. A wrong-arch binary, a truncated layer or a missing interpreter only
# shows up when something tries to exec it — which, on an air-gapped node, is
# the first time anyone finds out, hours after the ISO was written.
#
# --network none is the point: this is the environment the node has. An image
# that needs the network to start is an image that will not start there.
#
# What this does NOT judge: whether a server stays up. Half of these are
# one-shot tools, and several exit non-zero without their config — neither is a
# fault. The question is only "could the process be executed at all".
smoke_test_images() {
  local imgs; imgs=$(node_images)
  local broken=0 n=0
  log "smoke-testing $(echo "$imgs" | wc -l) images with no network"
  while read -r img; do
    [ -z "$img" ] && continue
    n=$((n + 1))
    local out
    out=$(timeout 60 docker run --rm --network none --entrypoint "" "$img" true 2>&1) || true
    if echo "$out" | grep -qiE "exec format error|no such file or directory|cannot execute"; then
      echo "   !! BROKEN: $img — $(echo "$out" | tail -1 | cut -c1-70)" >&2
      broken=$((broken + 1))
    fi
  done <<< "$imgs"
  if [ "$broken" -gt 0 ]; then
    echo "!! $broken of $n images cannot execute — refusing to bake them into an ISO" >&2
    exit 1
  fi
  log "all $n images execute offline"
}

stage_images() {
  local imgs; imgs=$(node_images)
  local n; n=$(echo "$imgs" | wc -l)
  log "$n image(s) to stage"

  local i=0
  while read -r img; do
    [ -z "$img" ] && continue
    i=$((i + 1))
    # timeout + retry for the same reason bake.sh does it: a stalled pull does
    # not fail, it hangs forever, and on a flaky link that is the common case.
    local ok=0
    if [ "$LOCAL_IMAGES" = 1 ] && docker image inspect "$img" >/dev/null 2>&1; then
      log "[$i/$n] $img — already local, not pulling"
      continue
    fi
    for attempt in 1 2 3; do
      log "[$i/$n] pull $img (attempt $attempt)"
      if timeout 1800 docker pull -q "$img" >/dev/null; then ok=1; break; fi
      echo "   ... stalled or failed, retrying" >&2
      sleep 5
    done
    [ "$ok" -eq 1 ] || { echo "!! FAILED to pull $img" >&2; exit 1; }
  done <<< "$imgs"

  # Before anything is archived: an image that cannot exec must not reach an ISO.
  smoke_test_images

  # What we are about to freeze, resolved to digests. Computed BEFORE the save
  # so it can be compared against what the existing archive holds.
  local manifest; manifest="$(mktemp)"
  : > "$manifest"
  while read -r img; do
    [ -z "$img" ] && continue
    digest=$(docker image inspect "$img" \
      --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null | sed 's/.*@//')
    echo "${img}@${digest:-<no-digest>}"
  done <<< "$imgs" | sort -u >> "$manifest"

  # CACHE: `docker save` is the single slowest step in the whole build, and it
  # is pure waste when nothing has moved. Compare digests, not tags — `:node` is
  # a moving tag, so a tag match proves nothing and a digest match proves
  # everything.
  if [ -f "$OUT/images.tar.gz" ] && cmp -s "$manifest" "$OUT/images.list"; then
    log "images.tar.gz is current ($(du -h "$OUT/images.tar.gz" | cut -f1), $n images) — skipping the save"
    rm -f "$manifest"
    return 0
  fi
  [ -f "$OUT/images.tar.gz" ] && log "image digests changed — re-saving"

  # One archive, kept as `docker save` of the whole list rather than a file per
  # image: save dedupes layers shared between images only when they go into the
  # same tar. That mattered more when this staged 18 of them; it costs nothing
  # now and keeps load-images.sh reading one file whatever the list becomes.
  log "saving $n images (this is the slow part)"
  local zip=gzip
  command -v pigz >/dev/null 2>&1 && zip="pigz"
  # shellcheck disable=SC2086
  docker save $(echo "$imgs" | tr '\n' ' ') | $zip -1 > "$OUT/images.tar.gz.tmp"
  mv -f "$OUT/images.tar.gz.tmp" "$OUT/images.tar.gz"

  # What actually got frozen. The tag alone tells you nothing a month from now:
  # `:node` is a moving tag, which is exactly why the digest is recorded.
  # Only the image that actually went into the archive. `docker images` lists
  # everything in the WORKSTATION's layer store — this box has 30-odd unrelated
  # images on it — and this file is copied to /etc/voipappz-images on the node,
  # where it is the answer to "what is on this machine". An unfiltered dump made
  # it claim images the node has never seen.
  # Written only AFTER a successful save, so the manifest and the archive can
  # never disagree — a list written first would make the next run skip a save
  # that had actually failed.
  mv -f "$manifest" "$OUT/images.list"

  log "images.tar.gz $(du -h "$OUT/images.tar.gz" | cut -f1)"
}

# ---------------------------------------------------------------- docker debs
#
# install.sh runs get.docker.com, which needs network. An offline ISO cannot, so
# the same packages are downloaded here instead — as a self-contained local apt
# REPOSITORY, not a pile of .debs.
#
# Both halves of that are load-bearing, and both were learned the hard way:
#
#   * `apt-get install -d` resolves against THE BUILDER CONTAINER'S installed
#     set, so every dependency the container already had was silently skipped —
#     libgssapi-krb5-2, libssh-4, libldap2, libbrotli1 and friends never got
#     downloaded, and the install died on the target with seven unmet
#     dependencies. `apt-cache depends --recurse` asks what docker-ce needs in
#     the abstract, which is the question that actually matters when the target
#     is a different machine.
#
#   * `dpkg -i *.deb` cannot satisfy pre-depends ordering (systemd-sysv
#     pre-depends on systemd, python3 on python3-minimal), and the usual repair,
#     `apt-get -f install`, has nothing to work with offline. Handing apt a real
#     repository instead lets it order the unpacking itself and install only
#     what the target is actually missing.
stage_debs() {
  # The package list comes from HCL — `var.os_packages` in os-image.pkr.hcl,
  # passed through by the shell-local provisioner. Defined in ONE place so the
  # list an operator edits is the list that gets downloaded; a copy here would
  # drift from the copy the autoinstall installs, and the failure mode is a
  # package that is on the CD but never installed (or worse, the reverse).
  #
  # The fallback is only for running this script by hand.
  : "${OS_PACKAGES:=docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin sngrep tcpdump ngrep chrony openssl ca-certificates htop iotop lsof strace jq vim git curl wget unzip net-tools ethtool traceroute mtr-tiny bind9-dnsutils iputils-ping iputils-tracepath make}"
  export OS_PACKAGES

  log "downloading $(echo "$OS_PACKAGES" | wc -w) OS packages for offline install"
  # Retried, because archive.ubuntu.com hands out 403s and resets connections
  # under load: one run here fetched 148MB and then failed eight packages, none
  # of them for any reason that persists. Acquire::Retries covers a single
  # package; the outer loop covers a run that still ends short. apt only fetches
  # what is missing from the cache dir, so a retry resumes rather than restarts.
  local ok=0
  for attempt in 1 2 3 4 5; do
    log "  apt attempt $attempt"
    if docker run --rm -e OS_PACKAGES -v "$(hostpath "$OUT/debs"):/out" ubuntu:24.04 bash -c '
    set -eu
    export DEBIAN_FRONTEND=noninteractive
    APTOPT="-o Acquire::Retries=10 -o Acquire::http::Timeout=30 -o Acquire::ForceIPv4=true"
    # shellcheck disable=SC2086
    apt-get $APTOPT update -qq
    apt-get $APTOPT install -y -qq ca-certificates curl >/dev/null
    # HTTPS for the Ubuntu archive, once ca-certificates is in. Plain HTTP to
    # archive.ubuntu.com serves most of the pool fine and then 403s a couple of
    # files consistently, across several mirror IPs — something in the path
    # filters it. Over TLS the same URLs fetch normally. Done after the first
    # update because switching before ca-certificates exists breaks apt outright.
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

    # The OS baseline. Docker, plus the tools you actually want present the
    # first time a node misbehaves — on an offline box you cannot apt-get them
    # later, so anything not in this list is not on the machine, ever.
    #
    #   sngrep/tcpdump/ngrep  the SIP and RTP capture tools. A voip node without
    #                         sngrep is a node you cannot debug a call on.
    #   chrony                time. RTP and SIP timers care, and a drifting
    #                         clock also breaks TLS certificate validity.
    #   openssl               `voipappz setup` generates the placeholder certs
    #                         with it, and neither Kong nor kamailio starts
    #                         without a certificate on disk.
    #   the rest              ordinary triage: what is listening, what is slow,
    #                         what is resolving, what a process is doing.
    WANT="${OS_PACKAGES}"

    # The full recursive closure, asked of the archive rather than of this
    # container. --no-recommends keeps it to what is genuinely required; the
    # other --no-* flags stop apt-cache walking relationships that are not
    # dependencies at all and dragging in half of main.
    DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests \
             --no-conflicts --no-breaks --no-replaces --no-enhances $WANT \
           | grep "^[a-zA-Z0-9]" | sed "s/:i386$//" | sort -u)

    cd /out
    cached=0
    # One at a time: apt-get download fails the WHOLE batch if any single name
    # is a virtual package with no candidate, and the closure always contains a
    # few of those. Skipping them individually is correct — a virtual package
    # has no file to fetch, and its providers are already in the list.
    for p in $DEPS; do
      # CACHE: skip anything already downloaded. apt-get names files
      # <package>_<version>_<arch>.deb, so the package name plus an underscore
      # is the prefix to test.
      #
      # This was `[ -f "$p"*.deb ]`, which is broken two ways: an unquoted glob
      # inside [ ] expands to MULTIPLE arguments and makes test error out, and
      # the bare name also prefix-matches unrelated packages (docker-ce would
      # match docker-ce-cli). Broken meant it re-downloaded all 150MB on every
      # single run.
      if ls "${p}"_*.deb >/dev/null 2>&1; then
        cached=$((cached + 1)); continue
      fi
      apt-get $APTOPT download "$p" 2>/dev/null || echo "   (skip virtual/unavailable: $p)"
    done

    # The repository index. Without it apt cannot read the directory as a source
    # at all, and the target falls back to dpkg with no dependency resolution —
    # which is the failure this whole rewrite exists to remove.
    [ "$cached" -gt 0 ] && echo "   reused $cached cached .deb (delete packer/build/payload/debs to force a refetch)"

    # The index is rebuilt every run even when nothing was downloaded: it has to
    # describe exactly what is in the directory now, and a stale Packages file
    # makes apt on the target ask for a version that is not there.
    apt-ftparchive packages . > Packages
    gzip -9c Packages > Packages.gz
    ls *.deb | wc -l
  '; then ok=1; break; fi
    echo "   ... apt run failed, retrying" >&2
    sleep 10
  done
  [ "$ok" -eq 1 ] || { echo "!! could not download the docker packages" >&2; exit 1; }
  # apt ran as root in the container, so debs/ and its partial/ subdirectory come
  # back root-owned and the workstation user cannot even list them. Hand
  # ownership back through a container, the same way packer/build.sh does — an
  # unprivileged user cannot chown what root wrote.
  docker run --rm -v "$(hostpath "$OUT"):/p" ubuntu:24.04 chown -R "$(id -u):$(id -g)" /p/debs

  # `apt-get download` writes into the cwd, so there is no partial/ to flatten —
  # only apt's own lock files to drop. Packages/Packages.gz must survive: they
  # ARE the repository, and without them the directory is just a pile of files.
  find "$OUT/debs" -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
  rm -f "$OUT/debs/lock"
  [ -s "$OUT/debs/Packages.gz" ] || { echo "!! no Packages.gz — the debs dir is not a usable apt repository" >&2; exit 1; }
  log "debs: $(find "$OUT/debs" -name '*.deb' | wc -l) packages, $(du -sh "$OUT/debs" | cut -f1) (local apt repo)"
}

case "${1:-all}" in
  stack)  stage_stack ;;
  images) stage_images ;;
  smoke)  smoke_test_images ;;
  debs)   stage_debs ;;
  all)    stage_stack; stage_debs; stage_images ;;
  *) echo "usage: $0 [all|stack|images|debs|smoke]" >&2; exit 1 ;;
esac

log "payload staged in $OUT"
du -sh "$OUT"/* 2>/dev/null || true
