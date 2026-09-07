#!/bin/sh
# make up — start the node on THIS machine, from the files in THIS directory.
#
# A developer's start button, not an installer: it fetches nothing, registers
# nothing, writes nothing. Two files decide everything and both live beside the
# Makefile — ./.env (the image tag and the secrets the image cannot derive) and
# ./config/va.yaml (the node itself, mounted read-only). `make setup` writes
# them; this refuses and points there when they are missing.
#
# It is not install.sh. `sh install.sh --start-only` starts an INSTALLED node
# out of $INSTALL_DIR, from the tag that installation recorded; this starts the
# node you are working on, here, from the tag you wrote down. The docker run is
# the same one, flag for flag — if you change one, change the other (and
# va-crystal's scripts/run-node.sh).
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

load_env_file 1
require_env VA_VOIP_IMAGE VA_FREESWITCH_PASSWORD VA_LICENSE_JWT_SECRET \
            VA_LICENSE_ENCRYPTION_KEY VA_SECRET_KEY
[ -f "$VA_CONFIG" ] || die "no $VA_CONFIG — the node's va.yaml is what this starts; run: make setup"
VA_CONFIG=$(cd "$(dirname "$VA_CONFIG")" && pwd)/$(basename "$VA_CONFIG")

require_docker
require_image

# ONE NODE PER HOST, and this is the check that was missing. --network host
# means the node owns this machine's SIP, RTP and control ports; a second node
# container holds them first, and the one you just started dies in an endless
# s6 restart loop with `bind ... Address already in use` buried in its log —
# while :4000 keeps answering, because the OTHER node is answering. Refuse, and
# name what to stop.
# Match on the IMAGE, never the name: a CI runner container called
# act-va-crystal-... is not a node, and refusing to start because of one is its
# own kind of wrong answer.
OTHERS=$(docker ps --filter network=host --format '{{.Names}} {{.Image}}' |
  awk -v me="$NODE" '$2 ~ /va-crystal/ && $1 != me { print }')
if [ -n "$OTHERS" ]; then
  printf '\n!! another node container already owns this host'\''s ports\n' >&2
  printf '%s\n' "$OTHERS" | sed 's/^/     /' >&2
  printf '   two --network host nodes cannot share :5060, :8090 and :4000\n' >&2
  # ASK, NEVER DECIDE. Stopping the node that is up may be stopping the one
  # taking calls, so the answer is the operator's; with no terminal to ask
  # (CI, a pipe) the answer is no and this refuses.
  ANSWER=n
  if [ -t 0 ]; then
    printf '   stop it and continue? (y/N): ' > /dev/tty
    IFS= read -r ANSWER < /dev/tty || ANSWER=n
  fi
  case "$ANSWER" in
    y|Y|yes)
      printf '%s\n' "$OTHERS" | while read -r _name _image; do
        printf '  stopping %s (%s)\n' "$_name" "$_image"
        docker stop "$_name" >/dev/null || die "could not stop $_name"
      done
      ;;
    *)
      printf '   stop it first:  docker stop %s\n\n' \
        "$(printf '%s' "$OTHERS" | head -1 | cut -d' ' -f1)" >&2
      exit 1
      ;;
  esac
fi

printf '\nVoIPAppz VoIP node\n'
say "env:    $VA_ENV_FILE"
say "config: $VA_CONFIG -> /tmp/node.yaml"
say "image:  $VA_VOIP_IMAGE"

# EVERY CHECK ABOVE THIS LINE. A `make up` that cannot start the node must not
# be the thing that stopped it.
if docker inspect "$NODE" >/dev/null 2>&1; then
  say "replacing the existing $NODE container"
  docker rm -f "$NODE" >/dev/null || die "could not remove the existing $NODE container"
fi

# --network host: a SIP node advertises its own addresses and takes RTP over a
# wide port range; a bridge would rewrite neither. The capabilities are what
# FreeSWITCH needs to set thread priorities and lock memory, and kamailio to
# manage its own sockets. The ulimits can only come from out here — nothing
# inside the image can raise its own rtprio or memlock, and a node without them
# runs FreeSWITCH with no real-time scheduling: fine while idle, jitter under
# load, and nothing names the cause.
set -- docker run -d --name "$NODE" \
  --network host \
  --restart unless-stopped \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_RESOURCE \
  --cap-add SYS_NICE --cap-add IPC_LOCK \
  --security-opt seccomp=unconfined \
  --ulimit rtprio=99 --ulimit nice=-19 \
  --ulimit memlock=-1:-1 --ulimit nofile=999999:999999 \
  -v "$VA_CONFIG:/tmp/node.yaml:ro" \
  -v voipappz-kamailio:/var/lib/kamailio \
  -e VA_PATH=/tmp/node.yaml \
  -e "FREESWITCH_PASSWORD=$VA_FREESWITCH_PASSWORD" \
  -e "VA_FREESWITCH_PASSWORD=$VA_FREESWITCH_PASSWORD" \
  -e "LICENSE_JWT_SECRET=$VA_LICENSE_JWT_SECRET" \
  -e "LICENSE_ENCRYPTION_KEY=$VA_LICENSE_ENCRYPTION_KEY" \
  -e "SECRET_KEY=$VA_SECRET_KEY"
# Optional, and only when this .env named them: the service flags and a broker
# URL that carries a credential (the bare one is in va.yaml).
[ -z "${VA_KAMAILIO:-}" ]   || set -- "$@" -e "VA_KAMAILIO=$VA_KAMAILIO"
[ -z "${VA_FREESWITCH:-}" ] || set -- "$@" -e "VA_FREESWITCH=$VA_FREESWITCH"
[ -z "${VA_NATS_URL_CREDENTIALED:-}" ] \
  || set -- "$@" -e "NATS_URL=$VA_NATS_URL_CREDENTIALED"
if [ -f ./config/ca-bundle.pem ]; then
  set -- "$@" -v "$(pwd)/config/ca-bundle.pem:/etc/ssl/va-ca-bundle.pem:ro" \
    -e SSL_CERT_FILE=/etc/ssl/va-ca-bundle.pem
fi

# SHOW THE COMMAND. Someone who cannot see how their container was made cannot
# reproduce it and cannot tell whether it got the real-time limits. The secret
# NAMES matter — they are what the image cannot derive — their values never
# appear, here or anywhere else.
printf '  $ '
for _a in "$@" "$VA_VOIP_IMAGE"; do
  case "$_a" in
    FREESWITCH_PASSWORD=*|VA_FREESWITCH_PASSWORD=*|LICENSE_JWT_SECRET=*|LICENSE_ENCRYPTION_KEY=*|SECRET_KEY=*|NATS_URL=*)
      printf '%s=<masked> ' "${_a%%=*}" ;;
    *) printf '%s ' "$_a" ;;
  esac
done
printf '\n'
_a=""

"$@" "$VA_VOIP_IMAGE" >/dev/null || die "could not start $NODE"
say "started $NODE from $VA_VOIP_IMAGE"

# VALIDATE THE NODE WE STARTED, not "something answers on :4000". With host
# networking every probe over 127.0.0.1 can be answered by a different
# container, which is how a dead node looked healthy: kamcmd goes through this
# container's own control socket, so a reply can only have come from ours.
node_failed() {
  printf '\n!! %s\n' "$1" >&2
  printf '   last lines of its log:\n' >&2
  docker logs --tail 15 "$NODE" 2>&1 | sed 's/^/     /' >&2
  printf '   the whole log: docker logs %s\n\n' "$NODE" >&2
  exit 1
}

attempt=0
while [ "$attempt" -lt 40 ]; do
  running || node_failed "$NODE stopped before it came up"
  docker exec "$NODE" kamcmd core.uptime >/dev/null 2>&1 && break
  attempt=$((attempt + 1))
  sleep 3
done
docker exec "$NODE" kamcmd core.uptime >/dev/null 2>&1 \
  || node_failed "kamailio in $NODE never answered its control socket"
say "kamailio is up (its own control socket answered)"

# THEN THE NODE ITSELF, and it gets its own wait: the node service starts after
# kamailio and its startup checks retry the broker before the API listens, so a
# single probe the moment kamailio answers is a probe of a service that has not
# been given the chance to start yet.
attempt=0
while [ "$attempt" -lt 40 ]; do
  running || node_failed "$NODE stopped before its API came up"
  curl -fsS --max-time 3 http://127.0.0.1:4000/health >/dev/null 2>&1 && break
  attempt=$((attempt + 1))
  sleep 3
done
curl -fsS --max-time 3 http://127.0.0.1:4000/health >/dev/null 2>&1 \
  || node_failed "$NODE never answered on :4000"
say "the node API answers on :4000"

# AND FREESWITCH, which is the slowest of the three and the reason a start used
# to report a node it had not finished starting: kamailio answers, :4000
# answers, and `health` — run that instant — calls media_freeswitch_esl,
# media_sofia_profiles and both media_options_* red because FreeSWITCH is still
# loading its modules. Thirty seconds later they are all green. Ask FreeSWITCH
# itself, over its own event socket with the password this container was given,
# so the answer cannot have come from another host container.
#
# Not fatal: a node started with VA_FREESWITCH=0 has no FreeSWITCH to wait for,
# and a FreeSWITCH that is genuinely broken belongs in the health report below
# with its reasons, not in a die() that hides it.
attempt=0
while [ "$attempt" -lt 30 ]; do
  running || node_failed "$NODE stopped before FreeSWITCH came up"
  docker exec "$NODE" sh -c \
    'fs_cli -p "$FREESWITCH_PASSWORD" -x status' >/dev/null 2>&1 && break
  attempt=$((attempt + 1))
  sleep 2
done
if docker exec "$NODE" sh -c \
     'fs_cli -p "$FREESWITCH_PASSWORD" -x status' >/dev/null 2>&1; then
  say "FreeSWITCH is up (its own event socket answered)"
else
  say "FreeSWITCH has not answered its event socket yet (health follows)"
fi

# The mounted YAML is only the node's intent until the CLI writes it into
# kamailio's database.
docker exec -e VA_CONFIG_PATH=/tmp/node.yaml "$NODE" voipappz sbc egress sync >/dev/null \
  || die "the node CLI could not apply $VA_CONFIG to kamailio"
say "applied $VA_CONFIG to kamailio"

# THE VERDICT IS A REPORT, NOT A GATE. Half of what `health` checks is remote —
# the mothership, the broker — and a node here is expected to run without them.
if docker exec "$NODE" voipappz health >/dev/null 2>&1; then
  say "$NODE is healthy"
else
  docker exec "$NODE" voipappz health 2>&1 | sed 's/^/    /' || true
  say "WARNING: $NODE is up but its health verdict is red (report above)"
fi

printf '\n\033[1m%s is up\033[0m\n' "$NODE"
say "health: http://127.0.0.1:4000/health   (or: make health)"
say "logs:   make logs"
say "CLI:    make cli ARGS=\"sbc egress status\""
printf '\n'
