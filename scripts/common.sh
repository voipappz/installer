#!/bin/sh
# Sourced by every scripts/*.sh command. Not a command itself.
#
# What all of them share: how to talk, how to stop, how to read ./.env, and
# what the node container is called. Nothing here starts, stops or writes
# anything — each command owns its own verbs.

# The node container. One per host: --network host means it owns this
# machine's SIP, RTP and control ports, so there is nothing to namespace.
NODE="${NODE:-va-voip}"

# The two files that describe this node, both beside the Makefile. `make setup`
# writes them; every other command reads them and invents nothing.
VA_ENV_FILE="${VA_ENV_FILE:-./.env}"
VA_CONFIG="${VA_CONFIG:-./config/va.yaml}"

say() { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# THE ENV FILE IS THE CONFIGURATION. KEY=VALUE lines, one layer of matching
# quotes stripped, comments and blanks skipped; anything else is an error
# rather than a line silently ignored. A value already in the environment wins,
# so `VA_VOIP_IMAGE=... make up` still overrides for one run.
#
# NO DEFAULTS ANYWHERE. A value that is not in the file or the environment is
# missing, and the command that needs it says so by name and stops. A node
# started from half a configuration is worse than one that did not start.
load_env_file() {  # 1: required (1 = the file must exist)
  if [ ! -f "$VA_ENV_FILE" ]; then
    [ "${1:-0}" = 1 ] || return 0
    die "no $VA_ENV_FILE — run: make setup"
  fi
  [ -r "$VA_ENV_FILE" ] || die "cannot read $VA_ENV_FILE"
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    _key=${_line%%=*}; _val=${_line#*=}
    case "$_key" in *[!A-Za-z0-9_]*|'') die "$VA_ENV_FILE: not KEY=VALUE: $_line" ;; esac
    case "$_val" in \"*\") _val=${_val#\"}; _val=${_val%\"} ;; \'*\') _val=${_val#\'}; _val=${_val%\'} ;; esac
    eval "[ -n \"\${$_key+x}\" ]" && continue
    eval "$_key=\$_val; export $_key"
  done < "$VA_ENV_FILE"
  _line=""; _key=""; _val=""
}

# NAME EVERY MISSING VALUE, not just the first: filling in a fresh .env should
# take one run to learn what it wants, not five.
require_env() {  # variable names
  _missing=""
  for _v in "$@"; do
    eval "_set=\${$_v:-}"
    [ -n "$_set" ] || _missing="$_missing $_v"
  done
  _set=""
  [ -z "$_missing" ] || die "$VA_ENV_FILE is missing:$_missing — run: make setup"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed here"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon"
}

# THE IMAGE MUST ALREADY BE HERE. Pulling a gigabyte nobody asked for is not a
# start button's job, and quietly running a different build than the tag names
# is worse. Say which node images the host does have — the answer is almost
# always a typo or a build that was never tagged.
require_image() {
  docker image inspect "$VA_VOIP_IMAGE" >/dev/null 2>&1 && return 0
  printf '\n!! no %s on this host\n' "$VA_VOIP_IMAGE" >&2
  _present=$(node_images)
  if [ -n "$_present" ]; then
    printf '   node images that ARE here:\n' >&2
    printf '%s\n' "$_present" | sed 's/^/     /' >&2
  fi
  printf '   set VA_VOIP_IMAGE in %s, or fetch one: make get\n\n' "$VA_ENV_FILE" >&2
  exit 1
}

node_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
    grep -E 'va-crystal' | grep -v '<none>' | head -10
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null)" = true ]; }

require_running() {
  running || die "$NODE is not running — start it with: make up"
}
