#!/bin/sh
# Load the container images the ISO carried onto this node. Runs ONCE, at first
# boot, from voipappz-loadimages.service.
#
# Why a boot unit and not a step in the installer's late-commands: `docker load`
# needs a RUNNING docker daemon, and there is none inside the installer's
# /target chroot — curtin can dpkg-install docker there but cannot start it. So
# the install copies the archive onto the disk and this unit drains it on the
# first boot, before voipappz-firstboot (and va-node-install) need it.
#
# This is the offline equivalent of bake.sh's `docker pull` loop, and it is what
# lets a node with no route out run at all. It also pins what would otherwise
# drift: a moving tag resolves to whatever is newest on the day, so two nodes
# installed a week apart would run different software. The disc carries one
# build, resolved once, at cut time.
set -eu

PARTS=/var/lib/voipappz/images
MANIFEST=/var/lib/voipappz/images.list
STAMP=/var/lib/voipappz/images.loaded

log() { echo "[voipappz-loadimages] $*"; }

[ -e "$STAMP" ] && { log "already loaded, nothing to do"; exit 0; }

# The archive arrives SPLIT: a single ISO9660 file cannot exceed 4GB and the
# archive has been over it. Reassembled by streaming rather than by writing the whole thing back out
# first — `cat` straight into `docker load` needs no second copy of it on a
# disk that is about to hold the unpacked layers too.
#
# An empty parts directory is NOT an error: an ISO can be cut without images
# (-var with_images=false), and such a machine can still become a node —
# va-node-install fetches the image, the slow online path.
if [ -z "$(ls -A "$PARTS" 2>/dev/null)" ]; then
  log "no image on the install media — va-node-install will fetch one"
  exit 0
fi

# The disc shipped a checksum for every part. Verify before loading: a rotted
# disc, or a copy that ran out of room during the install, is otherwise an
# obscure `docker load` error several minutes in — and after it, a machine with
# half an image and no way to tell which half.
SUMS=/var/lib/voipappz/images.sha256
if [ -s "$SUMS" ]; then
  log "verifying $(ls "$PARTS" | wc -l) part(s)"
  ( cd "$PARTS" && sha256sum -c "$SUMS" >/dev/null ) || {
    log "FATAL: the image parts do not match the checksums the disc shipped — the media or the copy is damaged"
    exit 1
  }
fi

log "loading $(du -sh "$PARTS" | cut -f1) from $(ls "$PARTS" | wc -l) parts (several minutes)"
cat "$PARTS"/part-* | docker load

# The image the manifest names must now be in the store. `docker load` exiting 0
# is not that: it reports what the archive held, and the parts are deleted
# next — after which there is no second attempt without network.
if [ -s "$MANIFEST" ]; then
  image="$(sed -n '1s/@.*//p' "$MANIFEST")"
  docker image inspect "$image" >/dev/null 2>&1 || {
    log "FATAL: loaded, but $image is not in the image store — keeping $PARTS"
    exit 1
  }
  log "loaded $image"
fi

# Only now. Deleting before the load succeeds would leave a machine with neither
# the archive nor the image, and no way back without network.
rm -rf "$PARTS"
log "freed $PARTS"

# What is on this machine, where va-node-install reads the tag to run.
[ -f "$MANIFEST" ] && cp "$MANIFEST" /etc/voipappz-images

docker images --format '{{.Repository}}:{{.Tag}}' | sort > "$STAMP"
log "loaded $(wc -l < "$STAMP") images"
