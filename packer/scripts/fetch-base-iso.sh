#!/bin/sh
# Fetch the Ubuntu Server ISO that packer/make-node-iso.sh remasters, once, and
# prove it arrived whole.
#
#   packer/scripts/fetch-base-iso.sh
#   BASE_ISO=ubuntu-24.04.4-live-server-amd64.iso packer/scripts/fetch-base-iso.sh
#
# Not Packer's own ISO downloader: it does not resume, so a stalled 3GB transfer
# restarts from zero and the build dies having done nothing. `curl -C -` picks
# up where it stopped.
#
# The checksum comes from the release directory's SHA256SUMS rather than being
# pinned here — a hardcoded hash goes stale the moment Ubuntu cuts a point
# release, and a stale hash reads as a corrupt download.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"       # packer/
CACHE="$HERE/cache"

BASE_ISO="${BASE_ISO:-ubuntu-24.04.4-live-server-amd64.iso}"
RELEASE="${RELEASE:-24.04}"
MIRROR="${MIRROR:-https://releases.ubuntu.com}"

log() { printf '>> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

mkdir -p "$CACHE"
TARGET="$CACHE/$BASE_ISO"

verify() {
  [ -f "$TARGET" ] || return 1
  log "verifying $BASE_ISO"
  _sums="$(curl -fsSL --retry 5 "$MIRROR/$RELEASE/SHA256SUMS")" \
    || die "could not fetch $MIRROR/$RELEASE/SHA256SUMS"
  # SHA256SUMS lines are "<64 hex>  *<filename>" — two spaces and a literal
  # asterisk for a binary file. Anchored at both ends so a longer filename
  # cannot match.
  _want="$(printf '%s\n' "$_sums" | sed -n "s/^\([0-9a-f]\{64\}\)[ *]*$BASE_ISO\$/\1/p")"
  [ -n "$_want" ] || die "$BASE_ISO is not listed in $MIRROR/$RELEASE/SHA256SUMS"
  _got="$(sha256sum "$TARGET" | cut -d' ' -f1)"
  [ "$_want" = "$_got" ] || return 1
  log "sha256 ok: $_got"
  return 0
}

if verify; then
  log "$TARGET is already present and correct"
  exit 0
fi

log "downloading $MIRROR/$RELEASE/$BASE_ISO (about 3GB, resumable)"
curl -fL -C - --retry 10 --retry-all-errors --progress-bar \
  -o "$TARGET" "$MIRROR/$RELEASE/$BASE_ISO" \
  || die "could not download $BASE_ISO"

# A truncated ISO still lists like an ISO; the only symptom is an unbootable
# disc at the far end, hours later.
verify || die "$BASE_ISO does not match the published SHA256 — delete $TARGET and retry"
log "$TARGET"
