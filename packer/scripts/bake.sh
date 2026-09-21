#!/bin/sh
# Bake-time provisioning. Runs as root via Packer's shell provisioner on BOTH
# the AMI and the .vdi build — that is the point of sharing one build block.
#
# The split enforced here is the whole design:
#   bake  = docker, the CLI, the stack templates, every container image
#   boot  = `voipappz setup` (secrets + node identity) and `voipappz up`
#
# install.sh already draws that line for us: BOOTSTRAP=0 means "install only,
# print the bring-up command instead of running it". So this script does not
# reimplement the installer, it just stops it one step early.
set -eu

INSTALL_DIR="${INSTALL_DIR:-/opt/voipappz}"
CLI_VERSION="${CLI_VERSION:-latest}"
IMAGE_VERSION="${IMAGE_VERSION:-unknown}"

echo "==> waiting for cloud-init (the AMI's base image is still settling)"
cloud-init status --wait >/dev/null 2>&1 || true

# apt can be held by unattended-upgrades on a fresh Canonical image; racing it
# gives "Could not get lock /var/lib/dpkg/lock-frontend" a minute into the build.
echo "==> waiting for the apt lock"
i=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && break
  sleep 5
done

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# curl for the installer, ca-certificates for TLS to GitHub/Docker Hub.
apt-get install -y -qq curl ca-certificates

STACK_SOURCE="${STACK_SOURCE:-local}"

if [ "$STACK_SOURCE" = "local" ]; then
  # Bake THIS checkout. packer/build.sh built /tmp/stack.tar.gz from the
  # working tree plus bin/voipappz, so nothing is fetched from GitHub. It is
  # also the only way to image an unreleased branch.
  echo "==> installing docker (get.docker.com — the same installer install.sh uses)"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh

  echo "==> unpacking the local stack into $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  tar -xzf /tmp/stack.tar.gz -C "$INSTALL_DIR"
  rm -f /tmp/stack.tar.gz
  chmod +x "$INSTALL_DIR/bin/voipappz"
  ln -sf "$INSTALL_DIR/bin/voipappz" /usr/local/bin/voipappz
else
  # This repository's OWN install.sh, from the release rather than the checkout
  # — the point of STACK_SOURCE=release is to bake what a customer would get.
  echo "==> installing docker + the voipappz CLI from release $CLI_VERSION"
  rm -f /tmp/stack.tar.gz
  BOOTSTRAP=0 INSTALL_DIR="$INSTALL_DIR" VERSION="$CLI_VERSION" \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh)"
fi

# Whichever path got us here, the CLI must actually run — a broken binary
# discovered at first boot is far more expensive than one found now.
voipappz version || voipappz --version

# ---------------------------------------------------------------- images
#
# Pre-pull the node image. This is what makes the built disk self-contained and
# what pins the moving `:node` tag to whatever it resolved to RIGHT NOW.
if [ -n "${DOCKERHUB_USERNAME:-}" ]; then
  echo "==> docker login (bake-time only)"
  echo "${DOCKERHUB_PASSWORD}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin
elif [ -s /tmp/docker-config.json ] && ! grep -q '^{}$' /tmp/docker-config.json; then
  # The host's existing login, forwarded by build.sh. Preferred over asking for
  # a password: the stack's images are private, and without a credential the
  # first pull fails with "pull access denied ... may require 'docker login'"
  # and the whole bake stops there.
  echo "==> using the forwarded registry credential"
  mkdir -p /root/.docker
  install -m 600 /tmp/docker-config.json /root/.docker/config.json
  # DOCKER_CONFIG explicitly, because writing the file is NOT enough here:
  # Packer runs this script with `sudo -E`, which PRESERVES HOME — so the docker
  # client looks in /home/<ssh-user>/.docker/config.json and never reads the
  # file we just placed under /root. The pull then fails with "pull access
  # denied" while the log says the credential was installed, which is a
  # thoroughly misleading pair of messages.
  export DOCKER_CONFIG=/root/.docker
fi
rm -f /tmp/docker-config.json

echo "==> pre-pulling the node image"
# ONE image, resolved by the same script install.sh and stage-payload.sh use,
# out of the unpacked stack rather than from a copy here — media and installer
# disagreeing about the tag is how an air-gapped node ends up with nothing to
# run and no way to fetch it. scripts/node-images.sh refuses an unresolved
# reference rather than staging an empty list.
"$INSTALL_DIR/scripts/node-images.sh" \
  | while read -r img; do
  [ -z "$img" ] && continue
  # timeout + retry, because a stalled pull does NOT fail — it hangs forever.
  # Observed here: image 13 of 18 sat with zero bytes of progress for 35
  # minutes while docker waited patiently, and the whole build waited with it.
  #
  # No `-q`: the progress output is what distinguishes "slow" from "dead" when
  # you are watching a build that has been running for an hour.
  ok=0
  for attempt in 1 2 3; do
    echo "    pull $img (attempt $attempt)"
    if timeout 900 docker pull "$img"; then ok=1; break; fi
    echo "    ... attempt $attempt failed or stalled, retrying" >&2
    sleep 5
  done
  [ "$ok" -eq 1 ] || { echo "FAILED to pull $img after 3 attempts" >&2; exit 1; }
done

# Record what we actually froze. `docker images --digests` is the honest answer
# to "what is in this image" once :latest has been resolved — the tag alone
# tells you nothing a month from now.
docker images --digests --format '{{.Repository}}:{{.Tag}}@{{.Digest}}' | sort > /etc/voipappz-images
echo "==> froze $(wc -l < /etc/voipappz-images) images"

# ---------------------------------------------------------------- first boot

install -m 0755 /tmp/firstboot.sh /usr/local/sbin/voipappz-firstboot
install -m 0644 /tmp/voipappz-firstboot.service /etc/systemd/system/voipappz-firstboot.service
systemctl enable voipappz-firstboot.service

cat > /etc/voipappz-image <<EOF
image_version=$IMAGE_VERSION
cli_version=$CLI_VERSION
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ---------------------------------------------------------------- hygiene
#
# Everything below is "must not survive into the image". Each line is a real
# way to ship a broken or leaky image, not boilerplate.

echo "==> cleaning up"

# The registry credential. Deleting it is the whole reason logging in was a
# separate step — the images are already in the layer store and no longer need
# it, but a leftover config.json ships the password to every node.
rm -rf /root/.docker /home/*/.docker

# Node identity. `make setup` writes .env at first boot; if install.sh or a
# curious operator left one behind, every instance from this image would share
# one set of secrets. Belt and braces — BOOTSTRAP=0 should mean it never
# existed.
rm -f "$INSTALL_DIR/.env"
rm -rf "$INSTALL_DIR/certs"/*.crt "$INSTALL_DIR/certs"/*.key

# Machine identity. A cloned /etc/machine-id makes systemd-journald, DHCP
# leases and anything keyed on it collide across instances; the empty-file form
# (not deleted) is what systemd expects so it regenerates on next boot.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# SSH host keys — otherwise every node from this image presents the SAME host
# key, which is both a warning storm and a real MITM exposure.
rm -f /etc/ssh/ssh_host_*

# cloud-init must re-run on the clone, or first boot inherits the BUILD host's
# instance data and firstboot.sh reads the wrong addresses.
cloud-init clean --logs --seed 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /var/log/wtmp /var/log/btmp
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true

# NOTE the build credential is deliberately NOT locked here. Packer still has
# to SSH back in to run shutdown_command, and `passwd -l` blocks password auth,
# so locking it now strands the build with the VM running. firstboot.sh expires
# it instead (`chage -d 0`), which forces a new password on first console login
# without making the shipped .vdi unloginnable. The AMI path is unaffected —
# its `ubuntu` user is key-only and this account does not exist there.

history -c 2>/dev/null || true
rm -f /root/.bash_history /home/*/.bash_history

sync
echo "==> bake complete: $IMAGE_VERSION"
