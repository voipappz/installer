#!/bin/sh
# First-boot configuration. Runs ONCE, from voipappz-firstboot.service.
#
# This is the half of `install.sh` that bake.sh deliberately skipped: node
# identity. It exists because an image must be identical on every instance and
# a node must not be — .env and config/va.yaml carry secrets and addresses, so
# they are generated HERE, on the running machine, never baked.
#
# `voipappz setup` is a wizard, but it has an unattended path built in: every
# prompt can be pre-answered with VOIPAPPZ_<LABEL>, which is exactly what
# --env-file feeds it (the installer's cli/src/commands/setup.cr, #answer_key). So this script's
# whole job is to produce a complete answer sheet and hand it over.
#
# The operator supplies the tenant-specific half via cloud-init / user-data at
# /etc/voipappz/installer.env (see installer.env.example). This script adds the
# half only the booted machine can know: its addresses.
set -eu

INSTALL_DIR="${INSTALL_DIR:-/opt/voipappz}"
ANSWERS=/etc/voipappz/installer.env
STAMP=/var/lib/voipappz/firstboot.done
MERGED=/run/voipappz-answers.env

log() { echo "[voipappz-firstboot] $*"; }

[ -e "$STAMP" ] && { log "already configured, nothing to do"; exit 0; }

# Retire the build credential. `voipappz` exists only on the VirtualBox image
# (Packer needed a way in before any key existed); expiring it forces a new
# password at the first console login, so the shipped .vdi has no usable
# default credential while staying administrable. Done BEFORE the answer-sheet
# check on purpose — an unconfigured node must still get this.
if id voipappz >/dev/null 2>&1; then
  chage -d 0 voipappz 2>/dev/null || true
fi

if [ ! -f "$ANSWERS" ]; then
  # Deliberately NOT a failure, and deliberately not a partial setup. An image
  # booted without an answer sheet is a perfectly good un-provisioned node —
  # the operator runs `voipappz setup` by hand. Guessing a domain or an admin
  # email here would produce a node that looks configured and is not.
  log "no $ANSWERS — leaving this node unconfigured"
  log "run: voipappz setup   (or supply $ANSWERS and reboot)"
  exit 0
fi

# ---------------------------------------------------------------- addresses
#
# EC2 exposes them over IMDS; VirtualBox has no IMDS at all, so every read is
# best-effort with a short timeout and a local fallback. Getting this wrong is
# not theoretical: a node whose internal address was set to its PUBLIC IP bound
# kamailio to the wrong interface, the ingress dispatcher never got an answer
# to its keepalives, and every call 404'd. Deriving it here is what stops that
# being a hand-entered value at all.

imds() { # imds <path> -> value, or empty
  _t=$(curl -fsS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || return 0
  curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $_t" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
}

# The address on the interface holding the default route. This is the LAN bind
# address — what kamailio's `listen=` must use, with the public address only
# ever `advertise`d.
local_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

INTERNAL_IP=$(imds local-ipv4); [ -n "$INTERNAL_IP" ] || INTERNAL_IP=$(local_ip)
EXTERNAL_IP=$(imds public-ipv4)

# No public address (VirtualBox, or an EC2 instance with no EIP): advertise the
# internal one. Advertising something unreachable is worse than advertising a
# private address — the far end would put it in Via/Contact and never come back.
[ -n "$EXTERNAL_IP" ] || EXTERNAL_IP="$INTERNAL_IP"

if [ -z "$INTERNAL_IP" ]; then
  log "FATAL: could not determine this node's address"
  exit 1
fi

log "internal=$INTERNAL_IP external=$EXTERNAL_IP"

# ---------------------------------------------------------------- answers

umask 077
cp "$ANSWERS" "$MERGED"

{
  echo ""
  echo "# --- appended by voipappz-firstboot ---"
  echo "VOIPAPPZ_EXTERNAL_IP=$EXTERNAL_IP"
  # BOTH internal-IP keys, because setup asks a different question depending on
  # how many interfaces it finds: "Internal IP" when there is one, "Choose
  # internal IP" (a numbered menu) when there are several. The menu also accepts
  # a literal address, so the same value answers either branch — and which
  # branch fires is a property of the instance, not something we can predict at
  # bake time.
  echo "VOIPAPPZ_INTERNAL_IP=$INTERNAL_IP"
  echo "VOIPAPPZ_CHOOSE_INTERNAL_IP=$INTERNAL_IP"
} >> "$MERGED"

PROFILE=$(awk -F= '$1 == "VA_PROFILE" { print $2 }' "$MERGED" | tail -1)
[ -n "$PROFILE" ] || PROFILE=app

cd "$INSTALL_DIR"

log "running voipappz setup"
if ! voipappz setup --env-file "$MERGED"; then
  log "setup FAILED — not starting the stack"
  rm -f "$MERGED"
  exit 1
fi
rm -f "$MERGED"

log "starting profile: $PROFILE"
voipappz up -p "$PROFILE"

mkdir -p "$(dirname "$STAMP")"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP"
log "done"
