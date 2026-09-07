#!/bin/sh
# make setup — the small wizard that writes the two files `make up` reads.
#
#   ./config/va.yaml   the node itself: its name, its internal and external IP
#   ./.env             the image tag and the secrets the image cannot derive
#
# The wizard is the image's own (`voipappz setup` with VA_PATH set: the
# node-only one — name, internal IP, external IP). This script does not ask
# those questions itself and never writes va.yaml by hand: the CLI in the image
# owns that file's shape, and this owns only where it lands. It also generates
# the FreeSWITCH and licence secrets into ./.env on a first run and reads them
# back on a rerun, so setting up twice never rotates what a node already uses.
#
# Safe to rerun: nothing here overwrites a value that is already there without
# saying so, and the CLI keeps the answers already in va.yaml as its defaults.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_docker
load_env_file          # optional: a first run has no .env yet

ask() {  # 1: prompt, 2: default -> answer on stdout
  printf '%s' "$1" > /dev/tty
  [ -z "$2" ] || printf ' [%s]' "$2" > /dev/tty
  printf ': ' > /dev/tty
  IFS= read -r _answer < /dev/tty || _answer=""
  [ -n "$_answer" ] || _answer=$2
  printf '%s' "$_answer"
}

ask_secret() {  # 1: prompt -> answer on stdout, never echoed
  printf '%s: ' "$1" > /dev/tty
  _stty=$(stty -g < /dev/tty)
  stty -echo < /dev/tty
  IFS= read -r _secret < /dev/tty || _secret=""
  stty "$_stty" < /dev/tty
  printf '\n' > /dev/tty
  printf '%s' "$_secret"
}

set_env_value() {  # 1: key, 2: value — one value in ./.env, replacing any old one
  [ -n "$2" ] || return 0
  touch "$VA_ENV_FILE"
  _tmp=$(mktemp "${VA_ENV_FILE}.tmp.XXXXXX")
  sed "/^$1=/d" "$VA_ENV_FILE" > "$_tmp"
  printf '%s=%s\n' "$1" "$2" >> "$_tmp"
  mv -f -- "$_tmp" "$VA_ENV_FILE"
  chmod 0600 "$VA_ENV_FILE"
}

[ -t 0 ] || die "make setup is interactive; it asks which image and which node this is"

printf '\nVoIPAppz node setup\n'
say "this writes $VA_ENV_FILE and $VA_CONFIG, and nothing else"

# ── the image ───────────────────────────────────────────────────────────────
# WHICH BUILD THIS NODE RUNS. Asked, never guessed: the tags on a developer's
# machine are a pile of builds and picking one for them is how you spend an
# afternoon debugging the wrong binary. `make get` is what puts one here.
step "The image"
PRESENT=$(node_images)
if [ -z "$PRESENT" ]; then
  die "no va-crystal image on this host — fetch one first: make get"
fi
say "node images on this host:"
printf '%s\n' "$PRESENT" | sed 's/^/     /'
VA_VOIP_IMAGE=$(ask "  image" "${VA_VOIP_IMAGE:-$(printf '%s' "$PRESENT" | head -1)}")
require_image
set_env_value VA_VOIP_IMAGE "$VA_VOIP_IMAGE"

# ── the node ────────────────────────────────────────────────────────────────
# THE CLI'S WIZARD, NOT OURS. VA_PATH points it at ./config/va.yaml so it runs
# the node-only wizard and writes just that file; with VA_PATH empty the same
# command runs the full host wizard (organization, domain, TLS), which belongs
# to the mothership and must never run for a node. --user keeps the files it
# writes owned by you rather than by root.
step "The node"
case "$VA_CONFIG" in
  /*) die "make setup writes into this directory; VA_CONFIG must be a relative path, not $VA_CONFIG" ;;
esac
CONFIG_REL=${VA_CONFIG#./}
mkdir -p "$(dirname "$VA_CONFIG")"
if [ -f "$VA_CONFIG" ]; then
  say "$VA_CONFIG exists; the wizard offers its values as the defaults"
fi
docker run --rm -it --network host \
  --user "$(id -u):$(id -g)" \
  --entrypoint voipappz \
  -e VA_PROJECT_DIR=/work -e VA_PATH="/work/$CONFIG_REL" \
  -v "$(pwd):/work" -w /work \
  "$VA_VOIP_IMAGE" setup < /dev/tty \
  || die "the image's setup wizard did not finish"
[ -f "$VA_CONFIG" ] || die "the wizard did not write $VA_CONFIG"

# The CLI generates these into ./.env; re-read them and say plainly if one is
# missing, because `make up` will refuse without them.
load_env_file
require_env VA_FREESWITCH_PASSWORD VA_LICENSE_JWT_SECRET VA_LICENSE_ENCRYPTION_KEY

# ── the API's signing secret ────────────────────────────────────────────────
# The node image refuses to start without SECRET_KEY, and it has to be the SAME
# value the API signs its tokens with — a node with its own is a node whose
# every token is rejected. The CLI cannot derive it, so it is asked for here.
step "The API's token-signing secret"
if [ -n "${VA_SECRET_KEY:-}" ]; then
  say "$VA_ENV_FILE already has VA_SECRET_KEY; keeping it"
else
  API=$(docker ps --format '{{.Names}}' | grep -E '(voipappz-)?api(-web)?-1$' | head -1 || true)
  KEY=""
  if [ -n "$API" ]; then
    say "container $API is running and has a SECRET_KEY"
    case "$(ask "  use that one? (y/n)" y)" in
      y|Y|yes) KEY=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$API" |
        sed -n 's/^SECRET_KEY=//p' | head -1) ;;
    esac
  fi
  [ -n "$KEY" ] || KEY=$(ask_secret "  SECRET_KEY (same value as the API's)")
  [ -n "$KEY" ] || die "the node image refuses to start without SECRET_KEY"
  set_env_value VA_SECRET_KEY "$KEY"
  KEY=""
fi

chmod 0600 "$VA_ENV_FILE"

printf '\n\033[1msetup done\033[0m\n'
say "env:    $VA_ENV_FILE (0600)"
say "config: $VA_CONFIG"
say "start:  make up"
printf '\n'
