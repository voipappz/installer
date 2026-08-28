#!/bin/sh
# MOVED FROM mothership/packer/make-installer-iso.sh and trimmed to the node
# case. Removed: the CLI/stack tarball and its unpacking, the 17-image split
# into 2000MB parts, the images.list copy, the firstboot and load-images units,
# the --installer-env answer sheet and its VA_PROFILE pinning, the
# VOIPAPPZ_IMAGE_PROFILES scope tag in the ISO name, the builder-container
# xorriso indirection with its hostpath() translation (this runs xorriso
# directly — in the container it is on PATH, on a workstation it is one
# apt-get), the root-owned chown-back that indirection needed, and the python3
# grub patch (the same two edits in awk; this repository keeps Python out).
# Kept, verbatim in substance: the staging tree, the @OS_PACKAGES@/@NETWORK@
# substitution with its post-check, the grub.cfg extract-patch-replace, the
# xorriso invocation with `-boot_image any replay`, and the reasoning attached
# to each.
#
# Cut the bootable, OFFLINE VA-Crystal NODE installer ISO.
#
#   packer/scripts/fetch-base-iso.sh              # once — the Ubuntu ISO
#   NODE_IMAGE=nirlevi/va-crystal:node-2026.08.27-2 \
#     packer/scripts/stage-payload.sh all         # the offline payload
#   IMAGE_VERSION=2026.08.27-2 RELEASE_VERSION=2026.08.27-1 packer/make-node-iso.sh
#
# Normally driven by node-iso.pkr.hcl, which sets NODE_IMAGE, IMAGE_VERSION,
# RELEASE_VERSION, ISO_NAME, SRC_ISO and OS_PACKAGES for it.
#
# What comes out is Ubuntu Server 24.04 remastered so that booting it installs,
# with no network at all: Ubuntu, Docker Engine, the four tools install.sh uses,
# install.sh itself, and ONE `docker save` archive of
# nirlevi/va-crystal:node-<version>.
#
# It does NOT install the node, and it carries nothing of the mothership. The
# operator runs the installer afterwards, against the archive that came with the
# disc — install.sh already has that path (VA_IMAGE_SOURCE=archive), so no
# installation logic exists here.
#
# It is NOT a Packer VM build: there is no machine and no disk to produce, only
# one ISO unpacked, added to, and written out again. That is why it runs on a
# hosted GitHub runner with no KVM.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"          # packer/
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PAYLOAD="$HERE/build/payload"
WORK="$HERE/build/iso"

SRC_ISO="${SRC_ISO:-$HERE/cache/ubuntu-24.04.4-live-server-amd64.iso}"
DEST_DIR="${DEST_DIR:-}"
NETWORK_FILE="${NETWORK_FILE:-}"
WITH_IMAGE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)     DEST_DIR="$2"; shift 2 ;;
    --network)  NETWORK_FILE="$2"; shift 2 ;;
    --no-image) WITH_IMAGE=0; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) printf '!! unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

log() { printf '>> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

abspath() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")" ;;
  esac
}

# TWO VERSIONS, and they are different numbers.
#
#   IMAGE_VERSION    what goes ON the disc: va-crystal's published node image
#                    tag. That version space belongs to va-crystal.
#   RELEASE_VERSION  what the disc IS: this media's own release, minted by
#                    .github/workflows/node-iso.yml. A disc re-cut around an
#                    unchanged image — a fixed autoinstall, a newer package
#                    closure — is a new RELEASE of the same IMAGE.
#
# The ISO is named by the release. Both are written into the identity stamp at
# the root of the disc, labelled, because an operator holding two discs has to
# be able to tell which is which.
IMAGE_VERSION="${IMAGE_VERSION:-}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
[ -n "$IMAGE_VERSION" ] || die "IMAGE_VERSION is not set — media must name the pinned node image it carries"
[ "$IMAGE_VERSION" != "latest" ] || die "IMAGE_VERSION must be pinned, never 'latest'"
[ -n "$RELEASE_VERSION" ] || die "RELEASE_VERSION is not set — media must name its own release"
[ "$RELEASE_VERSION" != "latest" ] || die "RELEASE_VERSION must be pinned, never 'latest'"
NODE_IMAGE="${NODE_IMAGE:-nirlevi/va-crystal:node-$IMAGE_VERSION}"
# `voipappz-node-`, deliberately NOT `va-crystal-node-`: that name already
# belongs to va-crystal's image tarballs in the same bucket, and two different
# artifacts versioned by two different repositories must not share a namespace.
ISO_NAME="${ISO_NAME:-voipappz-node-$RELEASE_VERSION.iso}"
SRC_ISO="$(abspath "$SRC_ISO")"

# ---------------------------------------------------------------- preflight

command -v xorriso >/dev/null 2>&1 || die "xorriso is not installed — sudo apt-get install -y xorriso"

[ -f "$SRC_ISO" ] || {
  printf '!! base ISO not found: %s\n' "$SRC_ISO" >&2
  printf '   fetch it once (it resumes and verifies the checksum):\n' >&2
  printf '     packer/scripts/fetch-base-iso.sh\n' >&2
  exit 1
}

# if/else rather than `A && B || C`: the runners' shellcheck reads that as
# SC2015 and fails the shell job, even though the container image used locally
# passes it. Same reason as b65459c.
if [ ! -d "$PAYLOAD/debs" ] || [ ! -s "$PAYLOAD/debs/Packages.gz" ]; then
  die "no apt repository in $PAYLOAD/debs — run packer/scripts/stage-payload.sh debs"
fi

: "${OS_PACKAGES:=}"
if [ -z "$OS_PACKAGES" ]; then
  [ -f "$HERE/os-packages.txt" ] || die "no OS_PACKAGES and no $HERE/os-packages.txt"
  OS_PACKAGES="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$HERE/os-packages.txt" | grep -v '^$' | tr '\n' ' ')"
fi
[ -n "$OS_PACKAGES" ] || die "the package list is empty"

: "${NETWORK_FILE:=$HERE/autoinstall/network.default.yaml}"
case "$NETWORK_FILE" in /*) ;; *) NETWORK_FILE="$HERE/$NETWORK_FILE" ;; esac
[ -f "$NETWORK_FILE" ] || die "network file not found: $NETWORK_FILE"

[ -f "$REPO_ROOT/install.sh" ] || die "install.sh is missing from $REPO_ROOT — this disc has nothing to install with"

# ---------------------------------------------------------------- stage
#
# Everything that lands on the disc, assembled here first so the xorriso call is
# a couple of -map arguments rather than a dozen.

log "staging disc contents"
rm -rf "$WORK"
mkdir -p "$WORK/add/va-crystal"
ADD="$WORK/add"

# The offline apt repository.
cp -a "$PAYLOAD/debs" "$ADD/va-crystal/debs"

# THE INSTALLER. Copied from this checkout, unmodified — the disc carries the
# same script the public one-line curl fetches, so a node installed from media
# and a node installed from the internet run identical code.
install -m 0755 "$REPO_ROOT/install.sh" "$ADD/va-crystal/install.sh"

# The wrapper the operator actually types. It sets two environment variables and
# execs install.sh; it contains no installation logic of its own.
install -m 0755 "$HERE/files/va-node-install" "$ADD/va-crystal/va-node-install"
install -m 0644 "$HERE/files/motd"            "$ADD/va-crystal/motd"

# The one container image.
if [ "$WITH_IMAGE" -eq 1 ]; then
  [ -f "$PAYLOAD/node-image.tar.gz" ] \
    || die "missing $PAYLOAD/node-image.tar.gz — run packer/scripts/stage-payload.sh image"

  # ISO9660 cannot hold a single file larger than 4GiB. Level 3 encodes bigger
  # ones as multi-extent, but that then has to be read correctly by BOTH xorriso
  # and the installer's isofs — two places to be wrong about the one file the
  # whole disc exists to carry. Refused here, loudly, rather than discovered on
  # a burned disc. (The mothership's ISO splits its 4.6GB archive into parts;
  # one node image is nowhere near that, and splitting would mean reassembling
  # before `docker load`, which install.sh has no path for.)
  _bytes="$(wc -c < "$PAYLOAD/node-image.tar.gz")"
  [ "$_bytes" -lt 4294967296 ] \
    || die "node-image.tar.gz is $_bytes bytes; ISO9660 cannot carry a file of 4GiB or more"

  cp "$PAYLOAD/node-image.tar.gz"        "$ADD/va-crystal/node-image.tar.gz"
  cp "$PAYLOAD/node-image.tar.gz.sha256" "$ADD/va-crystal/node-image.tar.gz.sha256"
  cp "$PAYLOAD/node-image.list"          "$ADD/va-crystal/node-image.list"
  log "image: $NODE_IMAGE, $(du -h "$PAYLOAD/node-image.tar.gz" | cut -f1)"
else
  # The autoinstall copies these unconditionally and a failing late-command
  # aborts the whole install, so the placeholders have to exist. va-node-install
  # reports a missing archive as a named error.
  : > "$ADD/va-crystal/node-image.list"
  log "image: none (--no-image) — this node's installer must reach a registry or S3"
fi

# ---------------------------------------------------------------- identity
#
# At the ROOT of the disc, in plain text, so an operator can answer "what is
# this disc" by mounting it — no boot, no install, no guessing from a filename.
# The same file is copied to /etc/va-crystal-node on every machine it builds.
_digest="$(sed -n 's/^digest=//p' "$PAYLOAD/node-image.list" 2>/dev/null || printf '')"
_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
_dirty=""
# Only asked when there IS a repository: outside one `git diff` fails, and
# reading that as "dirty" would stamp every disc built from a tarball as
# modified.
if [ "$_commit" != "unknown" ] && ! git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null; then
  _dirty=" (built from a modified working tree)"
fi
# Said out loud rather than stamped quietly: a disc nobody can trace back to a
# commit is the one thing this file exists to prevent, and the usual cause is
# git refusing a checkout it does not own (see build.sh's safe.directory).
[ "$_commit" != "unknown" ] \
  || log "WARNING: no git commit for $REPO_ROOT — this disc cannot be traced to a revision"

cat > "$ADD/va-crystal-node.txt" <<EOF
VA-Crystal VoIP node installer

  This disc installs ONE VoIP node, offline. It carries the operating system,
  Docker Engine, one container image, and the public installer. It does not
  carry, install or start a VoIPAppz mothership.

  RESTRICTED MEDIA. The container image on this disc is private: anyone with
  the disc can extract it. Do not copy, share or re-host it publicly.

  Two versions, and they are NOT the same number. The iso release is this
  disc; the node image is what va-crystal published and this disc carries.

iso release        = $RELEASE_VERSION
iso file           = $ISO_NAME
node image         = $NODE_IMAGE
node image version = $IMAGE_VERSION
node image digest  = ${_digest:-<none>}
image on disc      = $([ "$WITH_IMAGE" -eq 1 ] && printf 'yes' || printf 'no')
installer commit   = $_commit$_dirty
installer repo     = https://github.com/voipappz/installer
base iso           = $(basename "$SRC_ISO")
os packages        = $OS_PACKAGES
built              = $(date -u +%Y-%m-%dT%H:%M:%SZ)

After installing, log in and run:  va-node-install
EOF
cp "$ADD/va-crystal-node.txt" "$ADD/va-crystal/va-crystal-node.txt"

# ---------------------------------------------------------------- autoinstall
#
# Subiquity 23.10+ reads /autoinstall.yaml off the installation media root with
# no datasource plumbing at all — no `ds=nocloud`, no seed directory, no HTTP
# server. That is why this ISO needs only a one-word grub change.
#
# Two substitutions. @OS_PACKAGES@ comes from the same list stage-payload.sh
# downloaded, so the disc's contents and the installer's request cannot
# disagree. @NETWORK@ sits alone at column 0 and is replaced by the WHOLE
# `network:` key from its own file — `sed r`, not `s`, because the replacement
# is multi-line and indentation-sensitive.
sed -e "s|@OS_PACKAGES@|${OS_PACKAGES}|" \
    -e "/^@NETWORK@$/r $NETWORK_FILE" \
    -e "/^@NETWORK@$/d" \
    "$HERE/autoinstall/user-data" > "$ADD/autoinstall.yaml"

for _token in '@OS_PACKAGES@' '@NETWORK@'; do
  if grep -q -- "$_token" "$ADD/autoinstall.yaml"; then
    die "$_token was not substituted — the disc would carry a broken autoinstall"
  fi
done
log "network: $(basename "$NETWORK_FILE"); autoinstall will install $(printf '%s' "$OS_PACKAGES" | wc -w) packages"

# ---------------------------------------------------------------- grub
#
# Two changes, both minimal. `autoinstall` on the kernel command line is what
# stops subiquity prompting for confirmation before it uses /autoinstall.yaml —
# without it the "this will erase the disk" screen waits for a keypress forever,
# which presents as a hung unattended install. And a short timeout with an
# explicit default, so an untouched console proceeds on its own.
#
# awk, not python: this repository has no Python in it and does not acquire one
# for a two-line edit (CLAUDE.md, "Change discipline").
log "extracting and patching grub.cfg"
rm -f "$WORK/grub.cfg"
if ! _xout="$(xorriso -osirrox on -indev "$SRC_ISO" \
      -extract /boot/grub/grub.cfg "$WORK/grub.cfg" 2>&1)"; then
  printf '!! xorriso could not extract grub.cfg from %s\n' "$SRC_ISO" >&2
  printf '%s\n' "$_xout" | tail -20 >&2
  exit 1
fi
[ -s "$WORK/grub.cfg" ] || die "grub.cfg extracted empty from the base ISO"
# xorriso extracts with the source's read-only permissions.
chmod u+w "$WORK/grub.cfg"

# `---` separates installer arguments from kernel arguments, and `autoinstall`
# belongs on the installer side of it — inserted BEFORE the separator, not
# appended. The hwe-vmlinuz entry is patched too: the ISO carries a second
# menuentry booting the HWE kernel, and an operator who picks it would otherwise
# land in the INTERACTIVE installer with no hint why the other entry differed.
awk '
  {
    line = $0
    if (line ~ /^[[:space:]]*linux[[:space:]]+\/casper\/(hwe-)?vmlinuz/ && line !~ /autoinstall/) {
      if (sub(/ ---/, " autoinstall ---", line)) { patched++ }
      else { line = line " autoinstall"; patched++ }
    }
    if (line ~ /^set[[:space:]]+timeout=/) { line = "set timeout=5"; timeout = 1 }
    if (line ~ /^set[[:space:]]+default=/) { seen_default = 1 }
    print line
  }
  END {
    if (patched == 0) { exit 3 }
    if (timeout == 0) { print "set timeout=5" }
    if (seen_default == 0) { print "set default=0" }
  }
' "$WORK/grub.cfg" > "$WORK/grub.cfg.new" \
  || die "no \`linux /casper/vmlinuz\` line in grub.cfg — the base ISO layout changed"
mv -f "$WORK/grub.cfg.new" "$WORK/grub.cfg"
grep -q 'autoinstall' "$WORK/grub.cfg" || die "grub.cfg was not patched"

# ---------------------------------------------------------------- cut
#
# `-boot_image any replay` is the load-bearing flag: it copies the source ISO's
# boot records forward — the El Torito catalog for BIOS AND the embedded EFI
# system partition — so the result stays bootable both ways and under Secure
# Boot. Rebuilding those by hand is how remastered Ubuntu ISOs end up
# UEFI-unbootable. The signed EFI binaries are untouched; only grub.cfg changes,
# and grub.cfg is not what Secure Boot verifies.
log "writing $ISO_NAME"
rm -f "$WORK/$ISO_NAME"
xorriso \
  -indev "$SRC_ISO" \
  -outdev "$WORK/$ISO_NAME" \
  -boot_image any replay \
  -compliance no_emul_toc \
  -map "$ADD/va-crystal"          /va-crystal \
  -map "$ADD/va-crystal-node.txt" /va-crystal-node.txt \
  -map "$ADD/autoinstall.yaml"    /autoinstall.yaml \
  -map "$WORK/grub.cfg"           /boot/grub/grub.cfg \
  -padding 0

# Beside the ISO, in the same `<sha>  <name>` form install.sh already reads for
# image archives, and the same form `sha256sum -c` verifies.
( cd "$WORK" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256" )

log "built $(du -h "$WORK/$ISO_NAME" | cut -f1)  $(cut -c1-16 < "$WORK/$ISO_NAME.sha256")…"

# ---------------------------------------------------------------- deliver

if [ -n "$DEST_DIR" ]; then
  [ -d "$DEST_DIR" ] || die "$DEST_DIR does not exist — the ISO is at $WORK/$ISO_NAME"
  log "copying to $DEST_DIR"
  cp "$WORK/$ISO_NAME" "$DEST_DIR/$ISO_NAME.tmp"
  mv -f "$DEST_DIR/$ISO_NAME.tmp" "$DEST_DIR/$ISO_NAME"
  cp "$WORK/$ISO_NAME.sha256" "$DEST_DIR/$ISO_NAME.sha256"
  log "delivered $DEST_DIR/$ISO_NAME"
fi

echo
echo "   $WORK/$ISO_NAME"
echo "   boot it: it erases the disk, installs Ubuntu + Docker + install.sh"
echo "   and the node image with no network, then powers off."
echo
echo "   then, on that machine:  va-node-install"
