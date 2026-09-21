#!/usr/bin/env bash
# Install the ISO's payload onto a RUNNING machine, over SSH.
#
# Driven by os-image.pkr.hcl's `voipappz-deliver` build with
# -var deliver_install=true, after the ISO has been copied there. Runs as root
# (the provisioner's execute_command wraps it in sudo -S).
#
# These are the autoinstall's late-commands, in the same order, against a
# machine that already exists instead of one being built. Booting the disc is
# still the supported path — this is for a box you cannot reinstall.
set -euo pipefail

# No conditional provisioner exists in Packer, so the gate is here.
[ "${VA_INSTALL:-false}" = "true" ] || { echo ">> deliver_install not set — copied only, nothing installed"; exit 0; }

: "${OS_PACKAGES:?set by os-image.pkr.hcl}"
: "${ISO_DIR:?set by os-image.pkr.hcl}"

MNT=/mnt/voipappz-iso
REPO=/var/lib/voipappz/debs
APT_OPTS=(-o "Dir::Etc::sourcelist=/etc/apt/sources.list.d/voipappz-local.list"
          -o "Dir::Etc::sourceparts=/dev/null"
          -o "APT::Get::List-Cleanup=0")

iso=$(ls -t "$ISO_DIR"/voipappz-os-*.iso 2>/dev/null | head -1)
[ -n "$iso" ] || { echo "!! no ISO in $ISO_DIR" >&2; exit 1; }
echo ">> installing from $(basename "$iso")"

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o loop,ro "$iso" "$MNT"

# ---------------------------------------------------------------- packages
mkdir -p "$REPO"
cp -a "$MNT/voipappz/debs/." "$REPO/"
echo 'deb [trusted=yes] file:'"$REPO"' ./' > /etc/apt/sources.list.d/voipappz-local.list

# Priority above 1000 is the only band that lets a LOWER version win, and that
# is exactly what is needed: a machine that has ever had internet carries cached
# lists advertising NEWER versions from a mirror it cannot reach now, so apt
# picks those and then reports the package as "not available". Pinning the
# offline repo over them is what makes an air-gapped install resolve at all.
printf 'Package: *\nPin: origin ""\nPin-Priority: 1001\n' > /etc/apt/preferences.d/voipappz-local

apt-get "${APT_OPTS[@]}" update >/dev/null

# Best-effort, package by package, and NOT one `apt-get install` of the whole
# list. The payload is built for the ISO's own Ubuntu release; on a target
# running a DIFFERENT release the tools that pin an exact library version
# (`libcurl4t64 = 8.5.0`, `libjq1 = 1.7.1`, `vim-common = 9.1.0016`) cannot
# resolve against that machine's newer libraries, and one unsatisfiable package
# would otherwise abort the whole install — including docker, which resolves
# perfectly well. Report what was skipped rather than failing or hiding it.
installed=(); skipped=()
for pkg in $OS_PACKAGES; do
  if DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" \
       install -y --no-install-recommends "$pkg" >/dev/null 2>&1; then
    installed+=("$pkg")
  else
    skipped+=("$pkg")
  fi
done
echo ">> installed ${#installed[@]}: ${installed[*]}"
[ ${#skipped[@]} -eq 0 ] || {
  echo ">> SKIPPED ${#skipped[@]} (unsatisfiable on this release): ${skipped[*]}"
  echo "   the payload targets the ISO's Ubuntu release; boot the disc for a clean match"
}

command -v docker >/dev/null || { echo "!! docker did not install — stopping" >&2; exit 1; }
systemctl enable --now docker >/dev/null 2>&1 || true

# ---------------------------------------------------------------- images
# Straight off the mounted ISO: no second 4.6GB staged on a disk that is about
# to hold the unpacked layers too. The archive arrives split because a single
# ISO9660 file cannot exceed 4GB.
if [ -n "$(ls -A "$MNT/voipappz/images" 2>/dev/null)" ]; then
  echo ">> loading images ($(du -sh "$MNT/voipappz/images" | cut -f1), several minutes)"
  cat "$MNT"/voipappz/images/part-* | docker load
  [ -f "$MNT/voipappz/images.list" ] && cp "$MNT/voipappz/images.list" /etc/voipappz-images
  echo ">> $(docker images -q | sort -u | wc -l) images in the local store"
else
  echo ">> no images on the disc (--no-images build) — compose will pull"
fi

# ---------------------------------------------------------------- the CLI
# What `voipappz bootstrap` needs to exist before it can run. Deliberately NOT
# `voipappz setup`: that writes .env and config/va.yaml, which are secrets plus
# node identity, and belong to whoever operates the node.
mkdir -p /opt/voipappz
tar -xzf "$MNT/voipappz/stack.tar.gz" -C /opt/voipappz
chmod +x /opt/voipappz/bin/voipappz
ln -sf /opt/voipappz/bin/voipappz /usr/local/bin/voipappz
echo ">> CLI: $(voipappz --version 2>/dev/null || echo installed)"

umount "$MNT" || true
echo ">> done — run 'voipappz bootstrap' on this machine to bring the stack up"
