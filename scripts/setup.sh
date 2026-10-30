#!/bin/sh
# make setup — the small wizard that writes the two files `make up` reads.
#
#   ./config/va.yaml   the node itself: its name, its internal and external IP
#   ./.env             the image tag and the secrets the image cannot derive
#
# The wizard is the image's own (`voipappz setup` with VA_PATH set: the
# node-only one — name, internal IP, external IP). This script does not ask
# those questions itself: the CLI in the image owns the node configuration,
# and this script adds the mothership URL. It also generates
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

set_setup_url() { # section, URL
  case "$2" in
    *[[:space:]\'\"\\]*|*://*@*|*\?*|*\#*) die "enter a mothership URL without credentials, whitespace, quotes, query or fragment" ;;
  esac
  case "$1:$2" in
    mothership:https://?*|mothership:http://?*|broker:wss://?*|broker:ws://?*) ;;
    *) die "mothership needs http(s)://; Kong NATS needs ws(s)://" ;;
  esac
  _tmp=$(mktemp "${VA_CONFIG}.tmp.XXXXXX")
  awk -v section="$1" -v url="${2%/}" '
    $0 ~ "^" section ":[[:space:]]*(#.*)?$" { inside = 1; found = 1; print; next }
    inside && /^[^[:space:]#]/ {
      if (!wrote) { print "  url: " url; wrote = 1 }
      inside = 0
    }
    inside && /^[[:space:]]+url:/ {
      if (!wrote) print "  url: " url
      wrote = 1; next
    }
    { print }
    END {
      if (!found) print section ":"
      if (!wrote) print "  url: " url
    }
  ' "$VA_CONFIG" > "$_tmp"
  chmod 0644 "$_tmp"
  mv -f -- "$_tmp" "$VA_CONFIG"
}

setup_broker_url() {
  case "$1" in
    https://*) _scheme=wss ;;
    http://*) _scheme=ws ;;
    *) die "mothership URL must start with https:// or http://" ;;
  esac
  _authority=${1#*://}; _authority=${_authority%%/*}
  [ -n "$_authority" ] || die "mothership URL needs a hostname"
  printf '%s://%s/nats' "$_scheme" "$_authority"
}

verify_setup_broker() (
  # A real Upgrade and NATS INFO, not a 200 from Kong's SPA catchall.
  # This checks transport only; no credentials are sent or printed.
  case "$1" in
    *[[:space:]\'\"\\]*|*://*@*|*\?*|*\#*) die "NATS URL must not contain credentials or URL query/fragment" ;;
  esac
  case "$1" in
    wss://?*) probe_url=https://${1#wss://} ;;
    ws://?*) probe_url=http://${1#ws://} ;;
    *) die "Kong NATS URL must start with wss:// or ws://" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl is required to verify Kong NATS"
  probe_dir=$(mktemp -d)
  trap 'rm -rf "$probe_dir"' EXIT
  set -- --http1.1 --silent --show-error --connect-timeout 5 --max-time 5 \
    --dump-header "$probe_dir/headers" --output "$probe_dir/body" \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
  ca_bundle="$(dirname "$VA_CONFIG")/ca-bundle.pem"
  [ ! -f "$ca_bundle" ] || set -- "$@" --cacert "$ca_bundle"
  rc=0
  curl "$@" "$probe_url" 2> "$probe_dir/error" || rc=$?
  # An upgraded connection can stay open until our bounded timeout.
  case "$rc" in
    0|28) ;;
    *) cat "$probe_dir/error" >&2; die "Kong NATS connection failed" ;;
  esac
  if ! grep -q '^HTTP/1.1 101 ' "$probe_dir/headers" ||
     ! grep -qi '^Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=' "$probe_dir/headers" ||
     ! grep -aq 'INFO {"server_id":' "$probe_dir/body"; then
    die "Kong /nats did not return a WebSocket upgrade and NATS greeting; check the URL, port and broker"
  fi
  say "Kong NATS WebSocket verified (transport; authentication is checked when the node connects)"
)

[ -t 0 ] || die "make setup is interactive; it asks which image and which node this is"

printf '\nVoIPAppz node setup\n'
say "this writes $VA_ENV_FILE and $VA_CONFIG, and nothing else"

# ── the image ───────────────────────────────────────────────────────────────
# WHICH BUILD THIS NODE RUNS. Asked, never guessed: the tags on a developer's
# machine are a pile of builds and picking one for them is how you spend an
# afternoon debugging the wrong binary. `make get` is what puts one here.
step "The image"
# ghcr.io/voipappz/node:latest unless told otherwise — the image every node
# runs. Not pulled here: `make get` is the one command that fetches images, and
# require_image says so when it is missing.
VA_VOIP_IMAGE=$(ask "  image" "${VA_VOIP_IMAGE:-$DEFAULT_IMAGE}")
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

step "The mothership"
CURRENT_URL=$(sed -n '/^mothership:/,/^[^[:space:]#]/{ s/^[[:space:]]*url:[[:space:]]*//p; }' "$VA_CONFIG" |
  head -1 | tr -d "\"'")
VA_API_URL=$(ask "  Mothership URL (Kong)" "${VA_API_URL:-${CURRENT_URL:-https://cloud.voipappz.io}}")
BROKER_URL=$(ask "  Kong NATS URL (ws or wss)" "$(setup_broker_url "$VA_API_URL")")
verify_setup_broker "$BROKER_URL"
set_setup_url mothership "$VA_API_URL"
set_setup_url broker "$BROKER_URL"

# GENERATED HERE, ONCE. The node-only wizard writes va.yaml and nothing else, so
# the node-local secrets were never written and `make up` refused. They are
# minted on this host the first time and kept: a rerun reads them back and never
# rotates what a node already uses. 32 random bytes from the kernel as hex (64
# characters; the licence keys need 32+), so the host needs no openssl.
load_env_file
for _s in VA_FREESWITCH_PASSWORD VA_LICENSE_JWT_SECRET VA_LICENSE_ENCRYPTION_KEY; do
  eval "_have=\${$_s:-}"
  if [ -z "$_have" ]; then
    _new=$(od -An -tx1 -N32 /dev/urandom | tr -d " \n")
    set_env_value "$_s" "$_new"
    eval "$_s=\$_new; export $_s"
    say "generated $_s (kept in $VA_ENV_FILE)"
  fi
done
_new=""; _have=""

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
