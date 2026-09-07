#!/bin/sh
# make verify — read the two files this node runs on and say whether they are
# good. It starts nothing, writes nothing and needs no mothership.
#
# WHY IT EXISTS: the image fails loudly or not at all. A bad va.yaml or a
# missing secret halts the container before any service starts, so the report
# naming the problem is inside `docker logs` of something that is already
# dead — and half of what it checks (is that address really on this host? is
# :5060 free?) it can only discover the moment it binds. This asks the same
# questions out here, BEFORE `make up`, and names every problem at once
# instead of the first one.
#
# It is the node image contract, checked: the fields that must be right, the
# four values that live only in ./.env, and the ports the node must own.
# Warnings are things that are probably wrong; only a ✗ fails the run.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

FAILS=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

# ONE SCALAR OUT OF ONE SECTION, the same way install.sh reads them: the value
# of `key:` between `section:` at column 0 and the next line at column 0.
yaml_section_value() {  # 1: section, 2: key
  sed -n "/^$1:/,/^[^[:space:]#-]/{ s/^[[:space:]-]*$2:[[:space:]]*//p; }" "$VA_CONFIG" |
    head -1 | tr -d "\"'" | tr -d '[:space:]'
}
# The FIRST node's fields. One node per host — `--network host` sees to that —
# so the first entry under `nodes:` is this machine.
node_value() { yaml_section_value nodes "$1"; }

host_addresses() {
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
  elif command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n'
  fi
}

printf '\nVoIPAppz node — verifying the configuration in this directory\n'

# ── the two files ───────────────────────────────────────────────────────────
step "The two files"
if [ -f "$VA_ENV_FILE" ]; then
  MODE=$(stat -c %a "$VA_ENV_FILE" 2>/dev/null || stat -f %Lp "$VA_ENV_FILE" 2>/dev/null || echo '')
  ok "$VA_ENV_FILE${MODE:+ (mode $MODE)}"
  case "$MODE" in
    ''|600|400) ;;
    *) warn "$VA_ENV_FILE holds this node's secrets — chmod 0600 $VA_ENV_FILE" ;;
  esac
else
  bad "no $VA_ENV_FILE — run: make setup"
fi
if [ -f "$VA_CONFIG" ]; then
  ok "$VA_CONFIG"
else
  bad "no $VA_CONFIG — the node's va.yaml is what it boots from; run: make setup"
fi

# The environment still wins over the file, exactly as `make up` reads it, so
# what this verifies is what a start would use.
load_env_file

# ── ./.env ──────────────────────────────────────────────────────────────────
# The four values the image cannot derive plus the tag, and nothing else. Their
# VALUES are never printed, here or anywhere: set or missing is the whole
# answer.
step "The values only $VA_ENV_FILE can carry"
if [ -n "${VA_VOIP_IMAGE:-}" ]; then
  ok "VA_VOIP_IMAGE=$VA_VOIP_IMAGE"
else
  bad "VA_VOIP_IMAGE is missing — nothing here invents a tag; run: make setup"
fi
for _v in VA_FREESWITCH_PASSWORD VA_LICENSE_JWT_SECRET VA_LICENSE_ENCRYPTION_KEY VA_SECRET_KEY; do
  eval "_set=\${$_v:-}"
  if [ -n "$_set" ]; then
    ok "$_v is set"
  else
    bad "$_v is missing — the image halts at boot without it"
  fi
done
_set=""

# SECRET_KEY IS NOT THIS NODE'S TO CHOOSE. Cable verifies every websocket
# `?token=` against the API's own value, so a node with a different one
# authenticates nobody — and says nothing about why. When the API is running
# on this machine its value is readable, so compare (never print) the two.
if [ -n "${VA_SECRET_KEY:-}" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  API=$(docker ps --format '{{.Names}}' | grep -E '(voipappz-)?api(-web)?-1$' | head -1 || true)
  if [ -n "$API" ]; then
    API_KEY=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$API" 2>/dev/null |
      sed -n 's/^SECRET_KEY=//p' | head -1)
    if [ -z "$API_KEY" ]; then
      warn "container $API is running but exposes no SECRET_KEY to compare"
    elif [ "$API_KEY" = "$VA_SECRET_KEY" ]; then
      ok "VA_SECRET_KEY matches the API's ($API)"
    else
      bad "VA_SECRET_KEY differs from $API's SECRET_KEY — this node's tokens will be rejected"
    fi
    API_KEY=""
  fi
fi

# ── the image ───────────────────────────────────────────────────────────────
step "The image"
if ! command -v docker >/dev/null 2>&1; then
  bad "Docker is not installed here"
elif ! docker info >/dev/null 2>&1; then
  bad "cannot talk to the Docker daemon"
elif [ -z "${VA_VOIP_IMAGE:-}" ]; then
  warn "no tag to look for (VA_VOIP_IMAGE above)"
elif docker image inspect "$VA_VOIP_IMAGE" >/dev/null 2>&1; then
  ok "$VA_VOIP_IMAGE is on this host"
else
  bad "no $VA_VOIP_IMAGE on this host — fetch one: make get"
  _present=$(node_images)
  [ -z "$_present" ] || printf '%s\n' "$_present" | sed 's/^/      here: /'
fi

# ── config/va.yaml ──────────────────────────────────────────────────────────
# The image contract's table, field for field.
if [ -f "$VA_CONFIG" ]; then
  step "The node in $VA_CONFIG"

  UUID=$(node_value uuid)
  case "$UUID" in
    ????????-????-????-????-????????????) ok "node uuid $UUID" ;;
    '') bad "the node has no uuid — it is its identity everywhere; run: make setup" ;;
    *)  bad "node uuid is not a UUID: $UUID" ;;
  esac

  # BOUND DIRECTLY since the 2026.09.06 image: a wildcard or a defaulted
  # address no longer falls back to every interface, it fails.
  INTERNAL=$(node_value ip_address_internal)
  case "$INTERNAL" in
    '')          bad "ip_address_internal is empty — the node binds it directly" ;;
    127.0.0.1|::1) bad "ip_address_internal is loopback; the node must bind a real address" ;;
    0.0.0.0)     bad "ip_address_internal is a wildcard; the node binds one address, not all" ;;
    *)
      ADDRS=$(host_addresses)
      if [ -z "$ADDRS" ]; then
        warn "ip_address_internal $INTERNAL — cannot list this host's addresses to confirm it"
      elif printf '%s\n' "$ADDRS" | grep -qx "$INTERNAL"; then
        ok "ip_address_internal $INTERNAL is on this host"
      else
        bad "ip_address_internal $INTERNAL is not an address of this host — the bind will fail"
        printf '%s\n' "$ADDRS" | sed 's/^/      here: /'
      fi
      ;;
  esac

  EXTERNAL=$(node_value ip_address_external)
  if [ -n "$EXTERNAL" ]; then
    ok "ip_address_external $EXTERNAL (advertised)"
  else
    bad "ip_address_external is empty — it is the address the node advertises"
  fi

  # Kamailio holds 5060; sofia sits on 5070 and 5090 in the same network
  # namespace, so the three cannot collide.
  SIP_PORT=$(node_value sip_port)
  case "$SIP_PORT" in
    5060) ok "sip_port 5060 (kamailio)" ;;
    '')   bad "sip_port is empty — kamailio's front door is 5060" ;;
    5070|5090) bad "sip_port $SIP_PORT is FreeSWITCH sofia's; kamailio's is 5060" ;;
    *)    bad "sip_port $SIP_PORT — the node's SIP front door is 5060" ;;
  esac
  INT=$(yaml_section_value sip_interfaces port_internal)
  EXT=$(yaml_section_value sip_interfaces port_external)
  if [ -n "$INT" ] && [ "$INT" = "$EXT" ]; then
    bad "sofia's port_internal and port_external are both $INT; they share one namespace"
  elif [ -n "$INT" ] && { [ "$INT" = "$SIP_PORT" ] || [ "$EXT" = "$SIP_PORT" ]; }; then
    bad "sofia's ports ($INT/$EXT) collide with kamailio's $SIP_PORT"
  elif [ -n "$INT" ]; then
    ok "sofia $INT (phones) / $EXT (carriers)"
  fi

  MOTHERSHIP=$(yaml_section_value mothership url)
  case "$MOTHERSHIP" in
    https://*) ok "mothership $MOTHERSHIP" ;;
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*)
      ok "mothership $MOTHERSHIP (HTTP, on loopback)" ;;
    '') warn "no mothership.url — this node registers with nothing" ;;
    http://*) bad "mothership $MOTHERSHIP must use HTTPS (HTTP is allowed only on loopback)" ;;
    *)  bad "mothership.url is not a URL: $MOTHERSHIP" ;;
  esac
  case "$MOTHERSHIP" in
    https://*)
      if [ -f ./config/ca-bundle.pem ]; then
        ok "config/ca-bundle.pem — its certificate is pinned"
      fi ;;
  esac

  BROKER=$(yaml_section_value broker url)
  case "$BROKER" in
    '') bad "broker.url is required — the node needs an external NATS broker" ;;
    nats://*|tls://*|ws://*|wss://*) ok "broker $(printf '%s' "$BROKER" | sed 's#://[^@/]*@#://<credential>@#')" ;;
    *)  bad "broker.url is not a NATS URL: $BROKER" ;;
  esac
  # va.yaml is world-readable; ./.env is not. A broker credential belongs in
  # VA_NATS_URL_CREDENTIALED, which up.sh passes as NATS_URL.
  case "$BROKER" in
    *://*@*) warn "broker.url carries a credential in a world-readable file — put it in $VA_ENV_FILE as VA_NATS_URL_CREDENTIALED" ;;
  esac

  # ── the credential boundary ───────────────────────────────────────────────
  # Four values are ALWAYS the process environment and never the file. This
  # catches both the key and a value that leaked in beside it.
  step "The credential boundary"
  LEAKED=""
  for _k in LICENSE_JWT_SECRET LICENSE_ENCRYPTION_KEY SECRET_KEY VA_FREESWITCH_PASSWORD FREESWITCH_PASSWORD; do
    if grep -q "$_k" "$VA_CONFIG"; then LEAKED="$LEAKED $_k"; fi
  done
  for _v in VA_FREESWITCH_PASSWORD VA_LICENSE_JWT_SECRET VA_LICENSE_ENCRYPTION_KEY VA_SECRET_KEY; do
    eval "_set=\${$_v:-}"
    # A short value is not a secret; grep -F on it only invents matches.
    [ -n "$_set" ] && [ "${#_set}" -ge 8 ] || continue
    if grep -Fq "$_set" "$VA_CONFIG"; then LEAKED="$LEAKED $_v's value"; fi
  done
  _set=""
  if [ -z "$LEAKED" ]; then
    ok "no secret in $VA_CONFIG — they stay in $VA_ENV_FILE"
  else
    bad "$VA_CONFIG contains:$LEAKED"
  fi
fi

# ── the ports ───────────────────────────────────────────────────────────────
# What the node owns on this machine. Nothing else — no database, no broker
# beyond broker.url. `--network host` means a port held by anything else is a
# node that starts and dies in an s6 restart loop.
step "The ports this node needs"
if running; then
  ok "$NODE is running — it holds these ports itself"
else
  OTHERS=$(docker ps --filter network=host --format '{{.Names}} {{.Image}}' 2>/dev/null |
    awk -v me="$NODE" '$2 ~ /va-crystal/ && $1 != me { print }' || true)
  if [ -n "$OTHERS" ]; then
    bad "another host-network node container owns this host's ports:"
    printf '%s\n' "$OTHERS" | sed 's/^/      /'
  fi
  if command -v ss >/dev/null 2>&1; then
    LISTENERS=$(ss -H -lntu 2>/dev/null | awk '{ print $1, $5 }')
  elif command -v netstat >/dev/null 2>&1; then
    LISTENERS=$(netstat -lntu 2>/dev/null | awk '/^(tcp|udp)/ { proto = $1; sub(/[46]$/, "", proto); print proto, $4 }')
  else
    LISTENERS=""
    warn "neither ss nor netstat here — cannot tell whether the ports are free"
  fi
  BUSY=""
  if [ -n "$LISTENERS" ]; then
    for _p in tcp:5060 udp:5060 udp:5070 udp:5090 tcp:4000 tcp:8090 udp:9060; do
      _proto=${_p%%:*}; _port=${_p#*:}
      if printf '%s\n' "$LISTENERS" |
           awk -v p="$_proto" -v n="$_port" '$1 == p { sub(/.*:/, "", $2); if ($2 == n) hit = 1 } END { exit !hit }'; then
        BUSY="$BUSY $_proto/$_port"
      fi
    done
    if [ -z "$BUSY" ]; then
      ok "5060, 5070, 5090, 4000, 8090 and 9060 are free"
    else
      bad "already in use:$BUSY — the node cannot bind what something else holds"
    fi
  fi
fi

# ── the node that is running, if one is ─────────────────────────────────────
# Not a failure: it says whether what is UP was started from what was just
# verified, which is the difference between an edit that is live and an edit
# that is waiting for `make up`.
if running; then
  step "The node that is running"
  RUN_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$NODE" 2>/dev/null || true)
  if [ -n "${VA_VOIP_IMAGE:-}" ] && [ "$RUN_IMAGE" != "$VA_VOIP_IMAGE" ]; then
    warn "$NODE runs $RUN_IMAGE, not $VA_VOIP_IMAGE — restart it: make up"
  else
    ok "$NODE runs $RUN_IMAGE"
  fi
  RUN_YAML=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/tmp/node.yaml"}}{{.Source}}{{end}}{{end}}' "$NODE" 2>/dev/null || true)
  CONFIG_ABS=$(cd "$(dirname "$VA_CONFIG")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$VA_CONFIG")")
  if [ -n "$RUN_YAML" ] && [ "$RUN_YAML" != "$CONFIG_ABS" ]; then
    warn "$NODE was started from $RUN_YAML, not $CONFIG_ABS"
  elif [ -n "$RUN_YAML" ]; then
    ok "$NODE has $CONFIG_ABS mounted at /tmp/node.yaml"
  fi
fi

if [ "$FAILS" -eq 0 ]; then
  printf '\n\033[1mverify: green\033[0m — start it with: make up\n\n'
else
  printf '\n\033[1m!! %d problem(s)\033[0m — fix them, or rerun the wizard: make setup\n\n' "$FAILS" >&2
  exit 1
fi
