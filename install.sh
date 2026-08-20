#!/bin/sh
# VoIPAppz node installer — the one command a destination machine runs.
#
#   curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh
#
# THE PUBLIC ENDPOINT. This file — and only this file — is published to
# github.com/voipappz/installer, which is PUBLIC. Everything it pulls is
# private and sits behind ONE Docker Hub token.
#
# It is authored in the stack repo (installer/install.sh) so it is versioned
# with the thing it installs, and copied out by `make installer-publish`.
# One source, not two.
#
# NOTHING SECRET GOES IN THIS FILE. Its whole job is to ask for a credential,
# use it, and delete it.
#
# WHAT IT DOES
#   1. install docker, if absent
#   2. log in to the registry with the token you were given
#   3. pull ONE image and take the CLI and the stack out of it
#   4. DELETE the credential
#   5. hand over to `voipappz bootstrap` — login, setup, up, health
#
# WHAT IT BRINGS UP: bootstrap starts the APP profile. The voip plane is
# deliberately separate (`voipappz up -p voip`), because it is normally a
# different machine — see the profile split in docker-compose.yaml.
#
# WHY A REGISTRY AND NOT A DOWNLOAD. The images are private and already need a
# registry login, so routing the stack and the binary through the same channel
# means one credential and one thing to revoke — instead of a token, a release
# asset host, and two ways for them to disagree about what version shipped.
set -eu

# ─── what you can set ────────────────────────────────────────────────────────
#   VA_REGISTRY_USER   docker hub user       (prompted if absent)
#   VA_REGISTRY_TOKEN  docker hub token      (prompted if absent, never echoed)
#   VA_VOIP_IMAGE      override the image everything comes from
#   INSTALL_DIR        where the stack lands (default /opt/voipappz)
#   BOOTSTRAP=0        install only, do not bring anything up
# ONE image. It is pulled anyway to RUN the node, so the CLI and the stack ride
# along inside it — nothing else to host, version, or keep in step.
VA_VOIP_IMAGE="${VA_VOIP_IMAGE:-nirlevi/va-crystal:node}"
INSTALL_DIR="${INSTALL_DIR:-/opt/voipappz}"
BOOTSTRAP="${BOOTSTRAP:-1}"

# Root is needed for the filesystem (writing $INSTALL_DIR, linking into
# /usr/local/bin), but NOT necessarily for docker: if the user is in the docker
# group, `sudo docker` both demands a password nobody typed and writes the
# registry credential into ROOT's ~/.docker/config.json instead of theirs.
#
# So two separate decisions, each probed rather than assumed. Getting this wrong
# produced "registry login failed — check the user and token" when the real
# fault was sudo, which is a support call chasing the wrong thing.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
DOCKER=""
say() { printf '  %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# Same principle for the filesystem: elevate only if the destination actually
# needs it. /opt/voipappz does; a user-owned INSTALL_DIR does not, and demanding
# a password for a directory the caller can already write is how an unattended
# install stops dead on a machine where sudo is not passwordless.
pick_sudo_for() {
  _dir="$1"
  if mkdir -p "$_dir" 2>/dev/null && [ -w "$_dir" ]; then
    SUDO=""
  fi
}

pick_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER="docker"
  elif [ -n "$SUDO" ] && sudo -n docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  elif [ -n "$SUDO" ]; then
    say "docker needs elevation — sudo may ask for your password"
    sudo docker info >/dev/null 2>&1 || die "cannot talk to docker, with or without sudo"
    DOCKER="sudo docker"
  else
    die "cannot talk to the docker daemon — is it running?"
  fi
}

pick_sudo_for "$INSTALL_DIR"

printf '\nVoIPAppz node installer\n\n'

# ─── 1. docker ───────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  say "docker present ($(docker --version 2>/dev/null))"
  pick_docker
else
  say "installing docker …"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  $SUDO sh /tmp/get-docker.sh >/dev/null
  rm -f /tmp/get-docker.sh
  command -v docker >/dev/null 2>&1 || die "docker install failed"
fi
pick_docker

# ─── 2. the one credential ───────────────────────────────────────────────────
# Read from /dev/tty, not stdin: this script is usually the thing on stdin
# (`curl | sh`), so a plain `read` would consume the script's own remaining
# lines instead of waiting for a human. That failure looks like the installer
# silently skipping steps.
ask() {
  _prompt="$1"; _silent="${2:-}"
  [ -t 0 ] || [ -e /dev/tty ] || die "no terminal to prompt on — set VA_REGISTRY_USER and VA_REGISTRY_TOKEN"
  if [ -n "$_silent" ]; then
    stty -echo 2>/dev/null || true
    printf '  %s: ' "$_prompt" > /dev/tty
    read -r _reply < /dev/tty
    stty echo 2>/dev/null || true
    printf '\n' > /dev/tty
  else
    printf '  %s: ' "$_prompt" > /dev/tty
    read -r _reply < /dev/tty
  fi
  printf '%s' "$_reply"
}

[ -n "${VA_REGISTRY_USER:-}" ]  || VA_REGISTRY_USER="$(ask 'docker hub user')"
[ -n "${VA_REGISTRY_TOKEN:-}" ] || VA_REGISTRY_TOKEN="$(ask 'docker hub token' silent)"
[ -n "$VA_REGISTRY_USER" ]  || die "no registry user"
[ -n "$VA_REGISTRY_TOKEN" ] || die "no registry token"

# The credential is removed on ANY exit, including failure. A token left in
# ~/.docker/config.json on a customer machine is a registry credential shipped
# to a customer — and a failed install is exactly when nobody goes back to check.
cleanup_credential() {
  ${DOCKER:-docker} logout ${REGISTRY:+"$REGISTRY"} >/dev/null 2>&1 || true
}
trap cleanup_credential EXIT INT TERM

# Log in to the registry the IMAGE names, not to whatever `docker login`
# defaults to. With no server argument docker always uses Docker Hub, which is
# right while the image lives on Hub and silently wrong the moment VA_VOIP_IMAGE
# points anywhere else — the login succeeds against Hub and the pull is then
# denied by a registry nobody authenticated to.
#
# A reference is host-qualified only if its first segment looks like a host: it
# contains a dot or a colon, or is exactly localhost. `nirlevi/va-crystal:node`
# A bare `<namespace>/<repo>:<tag>` has neither, so it is Docker Hub — which is
# what an empty server argument means to `docker login`.
registry_of() {
  case "$1" in
    */*) _first="${1%%/*}"
         case "$_first" in
           localhost|*.*|*:*) printf '%s' "$_first" ;;
           *) printf '' ;;
         esac ;;
    *) printf '' ;;
  esac
}
REGISTRY="$(registry_of "$VA_VOIP_IMAGE")"

say "logging in to ${REGISTRY:-docker hub}"
printf '%s' "$VA_REGISTRY_TOKEN" \
  | $DOCKER login ${REGISTRY:+"$REGISTRY"} -u "$VA_REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
  || die "login to ${REGISTRY:-docker hub} failed — the user or token was not accepted"
VA_REGISTRY_TOKEN=""   # not needed again; do not keep it in the environment

# ─── 3. one pull, everything out of it ───────────────────────────────────────
say "pulling $VA_VOIP_IMAGE"
$DOCKER pull -q "$VA_VOIP_IMAGE" >/dev/null \
  || die "could not pull $VA_VOIP_IMAGE — the token may not have access to it"

cid="$($DOCKER create "$VA_VOIP_IMAGE" true)" || die "could not create a container from the image"
extract_cleanup() { $DOCKER rm -f "$cid" >/dev/null 2>&1 || true; cleanup_credential; }
trap extract_cleanup EXIT INT TERM

$SUDO mkdir -p "$INSTALL_DIR/bin"
$DOCKER cp "$cid:/usr/local/bin/voipappz" "$INSTALL_DIR/bin/voipappz" \
  || die "$VA_VOIP_IMAGE has no /usr/local/bin/voipappz"
$DOCKER cp "$cid:/stack/." "$INSTALL_DIR/" \
  || die "$VA_VOIP_IMAGE has no /stack — the image must carry the compose file and configs"

$SUDO chmod +x "$INSTALL_DIR/bin/voipappz"
$SUDO ln -sf "$INSTALL_DIR/bin/voipappz" /usr/local/bin/voipappz 2>/dev/null || true

say "installed $("$INSTALL_DIR/bin/voipappz" --version 2>/dev/null || echo '(version unavailable)')"

# ─── 4. bring it up ──────────────────────────────────────────────────────────
if [ "$BOOTSTRAP" = "1" ]; then
  printf '\n'
  say "voipappz bootstrap  (setup → up → health)"
  # --skip-login: we authenticated above and the credential is still live until
  # this script exits, so bootstrap must not prompt for it a second time.
  #
  # --ci when there is no terminal: `setup` is a wizard, and under `curl | sh`
  # with an answer file there is nobody to answer it. Without this an unattended
  # install hangs on the first question instead of finishing or failing.
  boot_args="--skip-login"
  [ -e /dev/tty ] || boot_args="$boot_args --ci"
  ( cd "$INSTALL_DIR" && $SUDO ./bin/voipappz bootstrap $boot_args )
else
  printf '\n'
  say "installed, not started. Bring it up with:"
  say "    cd $INSTALL_DIR && voipappz bootstrap"
fi
