#!/bin/sh
# casper/{vmlinuz,initrd} out of an Ubuntu live-server ISO, for image-disk-direct.
#
# qemu boots that kernel DIRECTLY, so GRUB never runs and there is nothing to
# type — the deterministic answer to the GRUB race that makes image-disk-from-iso
# flaky. Extracted here rather than left as a manual step.
#
# Root inside the container because apk needs it, then chown back: root-owned
# build artifacts are what breaks the NEXT run.
#
# Usage: ISO_DIR=<dir holding ubuntu-*-live-server-amd64.iso> scripts/extract-casper.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DOCKER="${DOCKER:-docker}"
CASPER="${CASPER:-packer/cache/casper}"

if [ -z "${ISO_DIR:-}" ]; then
  echo "!! set ISO_DIR=<dir holding ubuntu-*-live-server-amd64.iso>" >&2
  echo "   e.g. make image-disk-direct ISO_DIR=packer/cache" >&2
  exit 1
fi

# Already extracted is the common case; this target is on the path of every
# image-disk-direct run.
if [ -f "$CASPER/vmlinuz" ] && [ -f "$CASPER/initrd" ]; then
  exit 0
fi

# shellcheck disable=SC2012  # newest-first by mtime; Ubuntu names its ISOs
iso="$(ls -t "$ISO_DIR"/ubuntu-*-live-server-amd64.iso 2>/dev/null | head -1 || true)"
if [ -z "$iso" ]; then
  echo "!! no ubuntu-*-live-server-amd64.iso in $ISO_DIR" >&2
  exit 1
fi

echo ">> extracting casper/{vmlinuz,initrd} from $(basename "$iso")"
mkdir -p "$CASPER"
$DOCKER run --rm \
  -v "$(cd "$ISO_DIR" && pwd):/iso:ro" -v "$ROOT/$CASPER:/out" \
  alpine:3.22 sh -c "apk add --no-cache xorriso >/dev/null && \
    xorriso -osirrox on -indev '/iso/$(basename "$iso")' \
      -extract /casper/vmlinuz /out/vmlinuz \
      -extract /casper/initrd /out/initrd && \
    chmod 644 /out/vmlinuz /out/initrd && \
    chown $(id -u):$(id -g) /out/vmlinuz /out/initrd"
