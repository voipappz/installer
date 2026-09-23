#!/usr/bin/env bash
# Cut a bootable, OFFLINE VoIPAppz OS ISO.
#
#   packer/scripts/stage-payload.sh debs stack   # once — the offline payload
#   packer/make-installer-iso.sh                 # cuts the ISO
#
# What comes out is Ubuntu Server 24.04.4 remastered so that booting it installs
# an OPERATING SYSTEM with no network at all: Ubuntu, docker, the SIP and
# network tooling a node is debugged with, and the voipappz CLI binary.
#
# It does NOT install the VoIPAppz platform. `voipappz bootstrap` does that,
# afterwards, against a machine that already has everything it needs to run it.
# The split is why a docker packaging failure can no longer throw away a
# completed OS install — which it did, once, and cost the whole build.
#
# Why an ISO and not the .vdi/AMI the Packer template builds: those are disk
# images, which is the wrong shape for bare metal and for a hypervisor that
# wants installation media.
#
# It is NOT a Packer build. Packer boots a VM to produce a disk; here there is
# no VM and no disk to produce — the work is unpacking one ISO, adding files,
# and writing another. Driving that through a qemu source would add the GRUB
# race documented in CLAUDE.md for nothing. xorriso runs in the SAME builder
# image the Packer targets use (packer/Dockerfile.builder already carries it),
# so the toolchain stays containerised either way.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

IMAGE="${PACKER_BUILDER_IMAGE:-voipappz-packer:local}"
PAYLOAD="$HERE/build/payload"
WORK="$HERE/build/iso"

# The base ISO. Same file packer/cache holds for the qemu.installer target.
SRC_ISO="${SRC_ISO:-$HERE/cache/ubuntu-24.04.4-live-server-amd64.iso}"

# Where the finished ISO is delivered. Defaults to the Windows side, because
# that is where it gets attached to a VM or written to a USB stick from — a
# WSL-only path is not reachable by either.
DEST_DIR="${DEST_DIR:-}"

CLI_VERSION="${CLI_VERSION:-latest}"
INSTALLER_ENV="${INSTALLER_ENV:-}"
WITH_IMAGES=1
# Per-site addressing. A separate file so an ISO is not welded to one network.
NETWORK_FILE="${NETWORK_FILE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)        DEST_DIR="$2"; shift 2 ;;
    --no-images)   WITH_IMAGES=0; shift ;;
    --network)     NETWORK_FILE="$2"; shift 2 ;;
    --cli-version)   CLI_VERSION="$2"; shift 2 ;;
    --installer-env) INSTALLER_ENV="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { echo ">> $*"; }

# Bind mounts are resolved by the DAEMON, on the host. When this script runs
# inside the packer builder container (os-image.pkr.hcl's shell-local
# provisioners) our own paths are container paths that mean nothing there — the
# daemon would silently create empty directories at them and the build would
# produce an artifact with no payload. build.sh passes HOST_PACKER_DIR so we can
# translate back before handing anything to `docker run -v`.
HOST_HERE="${HOST_PACKER_DIR:-$HERE}"
hostpath() {
  # ABSOLUTE only. `docker run -v` treats anything that does not start with /
  # as a NAMED VOLUME, not a bind mount — so a relative path silently mounts a
  # fresh empty volume instead of the file you meant, and the failure surfaces
  # much later as "Media status : is blank" from a tool reading an empty file.
  #
  # This is not hypothetical: os-image.pkr.hcl passes SRC_ISO as
  # "${path.root}/${var.base_iso}", and Packer's path.root is RELATIVE ("."),
  # which produced exactly that.
  case "$1" in
    /*) printf '%s' "${1/#$HERE/$HOST_HERE}" ;;
    *)  printf '%s' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" | { read -r abs; printf '%s' "${abs/#$HERE/$HOST_HERE}"; } ;;
  esac
}

# Normalise up front too, so every later use (existence checks, error messages)
# talks about the same absolute path the mount will use.
SRC_ISO_ABS() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;; esac; }




SRC_ISO="$(SRC_ISO_ABS "$SRC_ISO")"

VERSION="${CLI_VERSION}-$(date -u +%Y%m%d-%H%M)"
# No scope in the name any more. The name used to carry one because this
# tooling cut media for two planes out of the mothership's compose file, and an
# app-only disc that looked like a full one was an air-gapped node with no image
# to start. In this repository there is one plane and one image, so every disc
# carries the same thing and the plain name is honest again.
NAME="voipappz-os-${VERSION}.iso"

# ---------------------------------------------------------------- preflight

[ -f "$SRC_ISO" ] || {
  echo "!! base ISO not found: $SRC_ISO" >&2
  echo "   fetch it once (Packer's downloader does not resume, so -C - matters):" >&2
  echo "   curl -fL -C - --retry 10 -o '$SRC_ISO' \\" >&2
  echo "     https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso" >&2
  exit 1
}

for f in stack.tar.gz debs; do
  [ -e "$PAYLOAD/$f" ] || { echo "!! missing $PAYLOAD/$f — run packer/scripts/stage-payload.sh first" >&2; exit 1; }
done

# ---------------------------------------------------------------- stage
#
# Everything that lands on the CD under /voipappz, assembled here first so the
# xorriso call is a single -map of one directory rather than a dozen.

log "staging CD contents"
rm -rf "$WORK"
mkdir -p "$WORK/add/voipappz"
ADD="$WORK/add"

# The CD payload is now just two things: the offline package repository, and the
# CLI. No container images, no answer sheet, no first-boot units — installing
# the PLATFORM is `voipappz bootstrap`, run against the machine this ISO builds.
cp "$PAYLOAD/stack.tar.gz" "$ADD/voipappz/stack.tar.gz"
cp -a "$PAYLOAD/debs"      "$ADD/voipappz/debs"

# Setup runs at FIRST BOOT, from this unit. Not at install time: there is no
# docker daemon in the installer's chroot, and setup writes .env and
# config/va.yaml — secrets and node identity that must never be baked into an
# image and cloned onto every machine built from it.
cp "$HERE/scripts/firstboot.sh"              "$ADD/voipappz/firstboot.sh"
cp "$HERE/files/voipappz-firstboot.service"  "$ADD/voipappz/"
cp "$HERE/scripts/load-images.sh"            "$ADD/voipappz/load-images.sh"
cp "$HERE/files/voipappz-loadimages.service" "$ADD/voipappz/"

# The container images. SPLIT into 2000MB parts because the archive is 4.6GB and
# a single ISO9660 file cannot exceed 4GB. ISO level 3 encodes larger files as
# multi-extent, but that then has to be read correctly by BOTH xorriso and the
# installer's isofs — two places to be wrong about the file the whole image
# depends on. Parts sidestep the limit and cost one `cat` at load time.
mkdir -p "$ADD/voipappz/images"
if [ "$WITH_IMAGES" -eq 1 ]; then
  [ -f "$PAYLOAD/images.tar.gz" ] || { echo "!! missing $PAYLOAD/images.tar.gz — run scripts/stage-payload.sh images" >&2; exit 1; }
  # Plain byte count and letter suffixes: this runs under BUSYBOX split inside
  # the builder image, which has neither `-d` (numeric suffixes) nor the `m`
  # size suffix, and fails with a usage dump rather than a clear error.
  # Alphabetical part-aa, part-ab, ... still reassemble in order under `cat`.
  split -b 2000000000 "$PAYLOAD/images.tar.gz" "$ADD/voipappz/images/part-"
  cp "$PAYLOAD/images.list" "$ADD/voipappz/images.list"
  log "images: $(wc -l < "$PAYLOAD/images.list") pre-pulled, split into $(find "$ADD/voipappz/images" -name 'part-*' | wc -l) parts"
else
  # The autoinstall copies both unconditionally and a failing late-command
  # aborts the install, so the placeholders have to exist. load-images.sh treats
  # an empty parts directory as "pull on demand", not as an error.
  : > "$ADD/voipappz/images.list"
  log "images: none (--no-images) — this node will pull at \`up\` time"
fi

# The operator's answer sheet, baked in only if one was named. Without it the
# node installs and then waits, unconfigured — see firstboot.sh on why guessing
# a domain is worse than doing nothing.
if [ -n "$INSTALLER_ENV" ]; then
  [ -f "$INSTALLER_ENV" ] || { echo "!! --installer-env $INSTALLER_ENV not found" >&2; exit 1; }
  install -m 0600 "$INSTALLER_ENV" "$ADD/voipappz/installer.env"
  log "baked answer sheet from $INSTALLER_ENV — this node will configure itself"

  # firstboot.sh reads VA_PROFILE and falls back to `app`, which is the
  # mothership's plane and not on this disc. Media cut here carries the node, so
  # pin `voip` unless the operator already answered — a node that comes up
  # looking for fifteen app images it does not have says nothing about why.
  if grep -q '^VA_PROFILE=' "$ADD/voipappz/installer.env"; then
    log "answer sheet already sets VA_PROFILE — leaving it alone"
  else
    echo "VA_PROFILE=voip" >> "$ADD/voipappz/installer.env"
    log "pinned VA_PROFILE=voip — this disc carries the node image"
  fi
else
  log "NOTE: no answer sheet. firstboot defaults to profile 'app', which is not"
  log "      what this disc carries — put VA_PROFILE=voip in an --installer-env"
  log "      sheet, or on the node run: voipappz up -p voip"
fi

# WHAT THE BAKED BINARY SAYS IT IS, not what was asked for. CLI_VERSION is an
# input and defaults to `latest`, which names nothing a month later: two discs
# cut a week apart both say "latest" and carry different binaries. The version
# is taken from the binary that is actually on this disc, by running it.
#
# Static, so it runs in this container whatever the container is. A failure
# here is not fatal — an unreadable version is worth less than a cut disc — but
# it is recorded as `unknown` rather than quietly inheriting CLI_VERSION.
cli_build=unknown
if tar -xzOf "$PAYLOAD/stack.tar.gz" bin/voipappz > "$WORK/voipappz.bin" 2>/dev/null; then
  chmod +x "$WORK/voipappz.bin"
  cli_build="$("$WORK/voipappz.bin" --version 2>/dev/null | head -1 | tr -d '\r')"
  [ -n "$cli_build" ] || cli_build=unknown
fi
log "CLI on this disc: $cli_build"

cat > "$ADD/voipappz/voipappz-image" <<EOF
image_version=$VERSION
cli_version=$CLI_VERSION
cli_build=$cli_build
source=installer-iso
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
EOF

# Subiquity 23.10+ reads /autoinstall.yaml off the installation media root with
# no datasource plumbing at all — no `ds=nocloud`, no seed directory, no HTTP
# server. That is the whole reason this ISO needs only a one-word grub change.
#
# @OS_PACKAGES@ is substituted from the SAME list stage-payload.sh downloaded,
# which os-image.pkr.hcl passes to both. One definition, so the CD's contents
# and the installer's request cannot disagree — a mismatch is either a package
# on the disc that never gets installed, or an install that asks for one the
# disc does not carry, and the second aborts the whole build.
: "${OS_PACKAGES:?set by os-image.pkr.hcl, or exported when running this by hand}"
: "${NETWORK_FILE:=$HERE/autoinstall/network.default.yaml}"
[ -f "$NETWORK_FILE" ] || { echo "!! network file not found: $NETWORK_FILE" >&2; exit 1; }

# Two substitutions into one file. @NETWORK@ sits alone at column 0 and is
# replaced by the WHOLE `network:` key from its own file — `sed r` rather than
# `s`, because the replacement is multi-line and indentation-sensitive, and
# `s|...|...|` would mangle both.
sed -e "s|@OS_PACKAGES@|${OS_PACKAGES}|" \
    -e "/^@NETWORK@$/r $NETWORK_FILE" \
    -e "/^@NETWORK@$/d" \
    "$HERE/autoinstall/user-data" > "$ADD/autoinstall.yaml"

for token in '@OS_PACKAGES@' '@NETWORK@'; do
  if grep -q -- "$token" "$ADD/autoinstall.yaml"; then
    echo "!! $token was not substituted — the ISO would carry a broken autoinstall" >&2
    exit 1
  fi
done
log "network: $(basename "$NETWORK_FILE")"
log "autoinstall will install $(echo "$OS_PACKAGES" | wc -w) packages"

# ---------------------------------------------------------------- grub
#
# Two changes, both minimal. `autoinstall` on the kernel command line is what
# stops subiquity prompting for confirmation before it uses /autoinstall.yaml —
# without it the "install will erase the disk" screen waits for a keypress
# forever, which presents as a hung unattended install. And a short timeout with
# an explicit default, so an untouched console proceeds on its own.
log "extracting and patching grub.cfg"
run_builder() {
  docker run --rm \
    -v "$(hostpath "$HERE"):/w" -v "$(hostpath "$SRC_ISO"):/src.iso:ro" \
    -w /w --entrypoint "$1" "$IMAGE" "${@:2}"
}

rm -f "$WORK/grub.cfg"
# Output captured rather than sent to /dev/null. It was suppressed, and that
# turned a real failure into a bare "exit 5" with nothing to read — the error
# xorriso prints IS the diagnosis, so it gets shown when the call fails.
if ! xorriso_out=$(run_builder xorriso -osirrox on -indev /src.iso \
      -extract /boot/grub/grub.cfg /w/build/iso/grub.cfg 2>&1); then
  echo "!! xorriso could not extract grub.cfg from $SRC_ISO" >&2
  echo "$xorriso_out" | tail -20 >&2
  exit 1
fi
[ -s "$WORK/grub.cfg" ] || {
  echo "!! grub.cfg extracted empty from the base ISO" >&2
  echo "$xorriso_out" | tail -20 >&2
  exit 1
}
# xorriso ran as root in the container AND extracts with the source's read-only
# permissions, so the file comes back root-owned and unwritable — and the
# workstation user cannot chmod what root owns. Hand it back through a container
# first, the same way packer/build.sh does.
docker run --rm -v "$(hostpath "$WORK"):/o" --entrypoint sh "$IMAGE" -c \
  "chown -R $(id -u):$(id -g) /o && chmod u+w /o/grub.cfg"

python3 - "$WORK/grub.cfg" <<'PY'
import re, sys

path = sys.argv[1]
cfg = open(path).read()

# Every `linux /casper/vmlinuz ... ---` line. `---` separates installer
# arguments from kernel arguments, and `autoinstall` belongs on the installer
# side of it, so it is inserted BEFORE the separator rather than appended.
def add_autoinstall(m):
    line = m.group(0)
    if "autoinstall" in line:
        return line
    return line.replace(" ---", " autoinstall ---", 1)

# hwe-vmlinuz too: the ISO carries a second menuentry booting the HWE kernel,
# and an operator who picks it from the menu would otherwise land in the
# INTERACTIVE installer with no hint why the other entry behaved differently.
patched, n = re.subn(r"(?m)^\s*linux\s+/casper/(?:hwe-)?vmlinuz.*$", add_autoinstall, cfg)
if n == 0:
    sys.exit("!! no `linux /casper/vmlinuz` line in grub.cfg — base ISO layout changed")

# A menu that waits forever is the same failure as a confirmation prompt that
# waits forever. 5s is enough to interrupt from a console and short enough that
# an unattended boot is not held up.
patched = re.sub(r"(?m)^set timeout=.*$", "set timeout=5", patched)
if "set timeout=" not in patched:
    patched = "set timeout=5\n" + patched
if "set default=" not in patched:
    patched = "set default=0\n" + patched

open(path, "w").write(patched)
print(f"   patched {n} kernel line(s)")
PY

# ---------------------------------------------------------------- cut
#
# `-boot_image any replay` is the load-bearing flag: it copies the source ISO's
# boot records forward — the El Torito catalog for BIOS AND the embedded EFI
# system partition — so the result stays bootable both ways and under Secure
# Boot. Rebuilding those by hand is how remastered Ubuntu ISOs end up
# UEFI-unbootable. The signed EFI binaries are untouched; only grub.cfg changes,
# and grub.cfg is not what Secure Boot verifies.
log "writing $NAME"
rm -f "$WORK/$NAME"
docker run --rm \
  -v "$(hostpath "$HERE"):/w" -v "$(hostpath "$SRC_ISO"):/src.iso:ro" \
  -w /w --entrypoint xorriso "$IMAGE" \
    -indev /src.iso \
    -outdev "/w/build/iso/$NAME" \
    -boot_image any replay \
    -compliance no_emul_toc \
    -map "/w/build/iso/add/voipappz"     /voipappz \
    -map "/w/build/iso/add/autoinstall.yaml" /autoinstall.yaml \
    -map "/w/build/iso/grub.cfg"         /boot/grub/grub.cfg \
    -padding 0

# Packer and xorriso both run as root in the container, so the artifact lands
# root-owned and the workstation user cannot even delete it without sudo. Hand
# it back the same way packer/build.sh does — through a container, since the
# unprivileged user cannot chown what root wrote.
docker run --rm -v "$(hostpath "$HERE/build"):/b" --entrypoint chown "$IMAGE" \
  -R "$(id -u):$(id -g)" /b/iso

log "built $(du -h "$WORK/$NAME" | cut -f1)"

# ---------------------------------------------------------------- deliver
#
# Built on ext4 and copied out, not written straight to /mnt/c: the Windows
# mount is 9p, and writing several GB through it is slow enough that a direct
# xorriso output turns a two-minute cut into a long one.
if [ -n "${HOST_PACKER_DIR:-}" ]; then
  # Running inside the packer builder container. A container writing a multi-GB
  # file to WSL's 9p mount dies with "cp: write error: I/O error" partway
  # through, so build.sh does this copy from the host once the build returns.
  log "built in-container — build.sh will deliver it to $DEST_DIR"
elif [ -d "$DEST_DIR" ]; then
  log "copying to $DEST_DIR (9p mount — this takes a while)"
  cp "$WORK/$NAME" "$DEST_DIR/$NAME.tmp"
  mv -f "$DEST_DIR/$NAME.tmp" "$DEST_DIR/$NAME"
  log "delivered $DEST_DIR/$NAME"
else
  echo "!! $DEST_DIR does not exist — leaving the ISO at $WORK/$NAME" >&2
fi

echo
echo "   boot it: it installs an OS with no network, then powers off."
echo "     packages → $(find "$ADD/voipappz/debs" -name '*.deb' | wc -l) .deb from the CD (docker, sngrep, tcpdump, …)"
echo "     CLI      → /opt/voipappz, symlinked onto PATH"
echo "     repo     → kept at /var/lib/voipappz/debs, the node's only apt source"
echo
echo "   then install the platform on that machine:"
echo "     voipappz bootstrap"
