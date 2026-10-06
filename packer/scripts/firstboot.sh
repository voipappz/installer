#!/bin/sh
# First boot of a machine built from node media. Runs from
# voipappz-firstboot.service, after voipappz-loadimages.
#
# IT DOES NOT INSTALL A NODE ITSELF. install.sh does that — setup, registration,
# the `docker run`, the systemd unit — and it is reached through
# va-node-install, the same command an operator types. This script used to be
# the mothership's: it ran `voipappz setup --env-file` and `voipappz up -p app`,
# which are compose commands, on a machine that has one container and no compose
# file. Two things survive from it:
#
#   * the build credential is retired on the machine, never in the image;
#   * node identity and secrets are generated HERE, on the running machine, and
#     are never baked into media.
#
# With no answer sheet it stops and says what to type. With one
# (/etc/voipappz/installer.env, baked by `--installer-env` or dropped in by
# hand) it runs the installer unattended. The sheet is install.sh's own answer
# file — KEY=VALUE, the settings README.md lists — not a format of its own.
set -eu

ANSWERS=/etc/voipappz/installer.env
STATE=/var/lib/voipappz
STAMP=$STATE/firstboot.done

log() { echo "[voipappz-firstboot] $*"; }

[ -e "$STAMP" ] && { log "already configured, nothing to do"; exit 0; }
mkdir -p "$STATE"

# Retire the build credential. `voipappz`/`voipappz` exists so the machine is
# administrable from its console the moment the install finishes; expiring it
# forces a new password at the first login, so the media carries no usable
# default. ONCE: this unit re-runs on every boot until the node is configured,
# and expiring the password each time would make an operator who is still
# working on the machine choose a new one after every reboot.
if [ ! -e "$STATE/password.expired" ] && id voipappz >/dev/null 2>&1; then
  chage -d 0 voipappz 2>/dev/null || true
  : > "$STATE/password.expired"
fi

if [ ! -f "$ANSWERS" ]; then
  # Deliberately NOT a failure, and deliberately not a guess. A machine booted
  # without answers is a perfectly good un-provisioned one; inventing a
  # mothership or an Account here would produce a node that looks configured
  # and is not.
  log "no $ANSWERS — this machine is not a node yet"
  log "run: sudo va-node-install   (or supply $ANSWERS and reboot)"
  exit 0
fi

# The sheet is handed over as a FILE, not sourced: install.sh already parses
# KEY=VALUE without evaluating it, and a sheet that carries an Account
# credential must not pass through a shell that would expand it.
log "running the installer with $ANSWERS"
if ! VA_ENV_FILE="$ANSWERS" /usr/local/sbin/va-node-install; then
  log "the installer FAILED — this machine is not a node; fix $ANSWERS and reboot,"
  log "or run: sudo va-node-install"
  exit 1
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP"
log "done"
