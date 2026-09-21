#!/bin/sh
# Load the container images the ISO carried onto this node. Runs ONCE, at first
# boot, from voipappz-loadimages.service.
#
# Why a boot unit and not a step in the installer's late-commands: `docker load`
# needs a RUNNING docker daemon, and there is none inside the installer's
# /target chroot — curtin can dpkg-install docker there but cannot start it. So
# the install copies the archive onto the disk and this unit drains it on the
# first boot, before voipappz-firstboot brings the stack up.
#
# This is the offline equivalent of bake.sh's `docker pull` loop, and it is what
# lets a node with no route out run at all. It also pins what would otherwise
# drift: `:node` is a moving tag, so a release tag fixes the CLI and
# the templates but NOT what compose pulls — two nodes installed a week apart
# would run different software. Resolving them once, at build time, freezes them.
set -eu

PARTS=/var/lib/voipappz/images
MANIFEST=/var/lib/voipappz/images.list
STAMP=/var/lib/voipappz/images.loaded

log() { echo "[voipappz-loadimages] $*"; }

[ -e "$STAMP" ] && { log "already loaded, nothing to do"; exit 0; }

# The archive arrives SPLIT: it is 4.6GB and a single ISO9660 file cannot exceed
# 4GB. Reassembled by streaming rather than by writing the whole thing back out
# first — `cat` straight into `docker load` needs no second copy of 4.6GB on a
# disk that is about to hold the unpacked layers too.
#
# An empty parts directory is NOT an error: an ISO can be cut without images
# (-var with_images=false), and such a node is still a working node — compose
# just pulls at `up` time, the slow online path.
if [ -z "$(ls -A "$PARTS" 2>/dev/null)" ]; then
  log "no images on the install media — they will be pulled on demand"
  exit 0
fi

log "loading $(du -sh "$PARTS" | cut -f1) from $(ls "$PARTS" | wc -l) parts (several minutes)"
cat "$PARTS"/part-* | docker load

# Only now. Deleting before the load succeeds would leave a node with neither
# the archive nor the images, and no way back without network.
rm -rf "$PARTS"
log "freed $PARTS"

# Where bake.sh's manifest lands, so a node from an ISO and a node from an image
# answer "what is on this machine" the same way.
[ -f "$MANIFEST" ] && cp "$MANIFEST" /etc/voipappz-images

docker images --format '{{.Repository}}:{{.Tag}}' | sort > "$STAMP"
log "loaded $(wc -l < "$STAMP") images"
