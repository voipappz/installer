#!/usr/bin/env bash
# Install the ISO's payload onto a machine that ALREADY HAS THE ISO.
#
#   packer/scripts/ssh-install.sh --host 192.168.137.10 --password secret
#   packer/scripts/ssh-install.sh --host node20 --key ~/.ssh/id_ed25519
#
# The install half of the `voipappz-deliver` Packer build, without the copy.
# Once a machine has the disc there is nothing to transfer, and re-sending 8.4GB
# to run a five-minute install is the expensive way to do nothing — measured at
# ~15 minutes on a slow link, against a file already there byte for byte.
#
# It runs the SAME scripts/remote-install.sh the Packer build runs, so the two
# paths cannot drift: packages from the disc's own apt repository, docker
# started, the node image loaded, the CLI onto PATH.
#
# The target needs NO internet. That is the whole point — everything comes off
# the mounted ISO.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

HOST=""; USER_NAME="voipappz"; KEY=""; PASSWORD=""; PORT="22"
ISO_DIR="/home/voipappz/isos"

while [ $# -gt 0 ]; do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --user)     USER_NAME="$2"; shift 2 ;;
    --key)      KEY="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --iso-dir)  ISO_DIR="$2"; shift 2 ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$HOST" ] || { echo "!! --host is required" >&2; exit 1; }
[ -n "$KEY$PASSWORD" ] || { echo "!! --key or --password is required" >&2; exit 1; }

# The package list comes from the Packer template, which is where it is defined
# once for the download, the autoinstall AND this. Reading it here rather than
# repeating it is what stops the three drifting.
OS_PACKAGES="$(python3 - "$HERE/../os-image.pkr.hcl" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
blk = re.search(r'variable "os_packages".*?default = \[(.*?)\]', s, re.S).group(1)
print(' '.join(re.findall(r'"([^"]+)"', blk)))
PY
)"

# known_hosts in a writable place: ~/.ssh is mounted READ-ONLY into the builder
# image (it holds your keys, and this has no business writing there), so
# accept-new otherwise prints "Failed to add the host to the list of known
# hosts" on every single connection. Per-run rather than persistent, which is
# what a container that is destroyed on exit can honestly offer.
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/voipappz-known-hosts -o ServerAliveInterval=30 -p $PORT"
if [ -n "$KEY" ]; then
  SSH="ssh $SSH_OPTS -i $KEY"
else
  command -v sshpass >/dev/null || { echo "!! sshpass not found — use --key, or run this through packer/build.sh's image" >&2; exit 1; }
  SSH="sshpass -p $PASSWORD ssh $SSH_OPTS"
fi

echo ">> installing on $USER_NAME@$HOST from the ISO in $ISO_DIR"

# sudo -E is refused outright by Ubuntu's default sudoers ("preserving the
# entire environment is not supported"), and it only WARNS — the variables are
# dropped and the script then sees none of its inputs. `sudo env VAR=...` is the
# form that actually carries them across.
#
# A password for sudo is the SSH password when there is one; with key auth the
# target must have passwordless sudo, since there is nothing to hand it.
$SSH "$USER_NAME@$HOST" "cat > /tmp/voipappz-remote-install.sh" < "$HERE/remote-install.sh"
$SSH "$USER_NAME@$HOST" "
  echo '${PASSWORD:-}' | sudo -S env \
    VA_INSTALL=true \
    OS_PACKAGES='$OS_PACKAGES' \
    ISO_DIR='$ISO_DIR' \
    bash /tmp/voipappz-remote-install.sh
"
