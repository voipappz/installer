#!/bin/sh
# make verify — read the two files this node runs on and say, in green and red,
# whether it can start. It starts nothing, writes nothing, fetches nothing.
#
# WHY IT EXISTS: the image fails loudly or not at all. A bad va.yaml or a
# missing secret halts the container before any service starts, so the report
# naming the problem ends up inside `docker logs` of something that is already
# dead — and half of what it checks (is that address really on this host? is
# :5060 free?) it can only discover the moment it tries to bind. This asks the
# same questions out here, BEFORE `make up`, and names every problem at once
# instead of the first one.
#
# It is the node image contract, checked: the fields that must be right, the
# values that live only in ./.env, and the ports the node must own. Every line
# that is not green says what to do about it. Green means start it.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

OKS=0; WARNS=0; FAILS=0

# ONE LINE PER ANSWER, colored by what the answer is: green is done, red is
# what stops the node, yellow is worth a look. A red line always carries the
# thing to do next, indented under it — a problem with no fix beside it is
# half a report.
ok()   { OKS=$((OKS + 1));   printf '  %s✓%s %s%s%s\n' "$C_GREEN$C_BOLD" "$C_OFF" "$C_GREEN" "$1" "$C_OFF"; }
warn() { WARNS=$((WARNS + 1)); printf '  %s!%s %s%s%s\n' "$C_YELLOW$C_BOLD" "$C_OFF" "$C_YELLOW" "$1" "$C_OFF"
         [ $# -lt 2 ] || printf '      %s%s%s\n' "$C_DIM" "$2" "$C_OFF"; }
bad()  { FAILS=$((FAILS + 1)); printf '  %s✗%s %s%s%s\n' "$C_RED$C_BOLD" "$C_OFF" "$C_RED" "$1" "$C_OFF"
         [ $# -lt 2 ] || printf '      %s→ %s%s\n' "$C_DIM" "$2" "$C_OFF"; }
note() { printf '      %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

# ONE SCALAR OUT OF ONE SECTION, the same way install.sh reads them: the value
# of `key:` between `section:` at column 0 and the next line at column 0. The
# leading `-` is allowed so the first item of a list is reachable.
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

printf '\n%sVoIPAppz node — can this node start?%s\n' "$C_BOLD" "$C_OFF"
printf '%s  checking %s and %s. Nothing is started or written.%s\n' \
  "$C_DIM" "$VA_ENV_FILE" "$VA_CONFIG" "$C_OFF"

# ── the two files ───────────────────────────────────────────────────────────
step "The two files this node is made of"
if [ -f "$VA_ENV_FILE" ]; then
  MODE=$(stat -c %a "$VA_ENV_FILE" 2>/dev/null || stat -f %Lp "$VA_ENV_FILE" 2>/dev/null || echo '')
  ok "$VA_ENV_FILE is here${MODE:+ (mode $MODE)}"
  case "$MODE" in
    ''|600|400) ;;
    *) warn "anyone on this host can read $VA_ENV_FILE, and it holds the secrets" \
            "chmod 0600 $VA_ENV_FILE" ;;
  esac
else
  bad "$VA_ENV_FILE is missing — it carries the image tag and the secrets" \
      "run: make setup"
fi
if [ -f "$VA_CONFIG" ]; then
  ok "$VA_CONFIG is here"
else
  bad "$VA_CONFIG is missing — this file IS the node" "run: make setup"
fi

# The environment still wins over the file, exactly as `make up` reads it, so
# what this verifies is what a start would actually use.
load_env_file

# ── ./.env ──────────────────────────────────────────────────────────────────
# The four values the image cannot derive, plus the tag. Their VALUES are never
# printed, here or anywhere: set or missing is the whole answer.
step "The values only $VA_ENV_FILE can carry"
if [ -n "${VA_VOIP_IMAGE:-}" ]; then
  ok "image tag: $VA_VOIP_IMAGE"
else
  bad "VA_VOIP_IMAGE is not set — nothing here invents a tag" "run: make setup"
fi
for _v in VA_FREESWITCH_PASSWORD VA_LICENSE_JWT_SECRET VA_LICENSE_ENCRYPTION_KEY VA_SECRET_KEY; do
  eval "_set=\${$_v:-}"
  if [ -n "$_set" ]; then
    ok "$_v is set"
  else
    bad "$_v is not set — the image stops at boot without it" \
        "run: make setup (it generates or asks for it)"
  fi
done
_set=""

# SECRET_KEY IS NOT THIS NODE'S TO CHOOSE. Cable verifies every websocket
# `?token=` against the API's own value, so a node with a different one
# authenticates nobody — and says nothing about why. When the API runs on this
# machine its value is readable, so compare the two (never print either).
if [ -n "${VA_SECRET_KEY:-}" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  API=$(docker ps --format '{{.Names}}' | grep -E '(voipappz-)?api(-web)?-1$' | head -1 || true)
  if [ -n "$API" ]; then
    API_KEY=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$API" 2>/dev/null |
      sed -n 's/^SECRET_KEY=//p' | head -1)
    if [ -z "$API_KEY" ]; then
      warn "$API is running but exposes no SECRET_KEY to compare against"
    elif [ "$API_KEY" = "$VA_SECRET_KEY" ]; then
      ok "VA_SECRET_KEY is the same one the API signs with ($API)"
    else
      bad "VA_SECRET_KEY is NOT the API's ($API) — every token this node gets is rejected" \
          "copy SECRET_KEY out of $API into $VA_ENV_FILE, or run: make setup"
    fi
    API_KEY=""
  fi
fi

# ── the image ───────────────────────────────────────────────────────────────
step "The image"
if ! command -v docker >/dev/null 2>&1; then
  bad "Docker is not installed on this host" "install it: sh install.sh --image-only"
elif ! docker info >/dev/null 2>&1; then
  bad "the Docker daemon does not answer" "start it, or add yourself to the docker group"
elif [ -z "${VA_VOIP_IMAGE:-}" ]; then
  warn "no tag to look for (VA_VOIP_IMAGE is not set, above)"
elif docker image inspect "$VA_VOIP_IMAGE" >/dev/null 2>&1; then
  ok "$VA_VOIP_IMAGE is on this host"
else
  bad "$VA_VOIP_IMAGE is not on this host" "fetch it: make get"
  _present=$(node_images)
  if [ -n "$_present" ]; then
    note "node images that ARE here:"
    printf '%s\n' "$_present" | sed "s/^/        $C_DIM/; s/\$/$C_OFF/"
  fi
fi

# ── config/va.yaml ──────────────────────────────────────────────────────────
# The image contract's table, field for field.
if [ -f "$VA_CONFIG" ]; then
  step "The node itself, in $VA_CONFIG"

  UUID=$(node_value uuid)
  case "$UUID" in
    ????????-????-????-????-????????????) ok "node uuid $UUID" ;;
    '') bad "this node has no uuid — it is its identity to the mothership" "run: make setup" ;;
    *)  bad "the node uuid is not a UUID: $UUID" "fix it in $VA_CONFIG, or run: make setup" ;;
  esac

  # BOUND DIRECTLY since the 2026.09.06 image: a wildcard or a defaulted
  # address no longer falls back to every interface, it fails.
  INTERNAL=$(node_value ip_address_internal)
  case "$INTERNAL" in
    '') bad "ip_address_internal is empty — the node binds this address directly" \
            "put this host's LAN address in $VA_CONFIG, or run: make setup" ;;
    127.0.0.1|::1)
        bad "ip_address_internal is loopback — nothing outside this box could reach the node" \
            "use the address phones and carriers see" ;;
    0.0.0.0)
        bad "ip_address_internal is a wildcard — the node binds ONE address, not all of them" \
            "name the real address of this host" ;;
    *)
      ADDRS=$(host_addresses)
      if [ -z "$ADDRS" ]; then
        warn "ip_address_internal $INTERNAL — cannot list this host's addresses to confirm it"
      elif printf '%s\n' "$ADDRS" | grep -qx "$INTERNAL"; then
        ok "ip_address_internal $INTERNAL — an interface here holds it"
      else
        bad "no interface on this host holds $INTERNAL — the node cannot bind it" \
            "use one of the addresses below, or run: make setup"
        printf '%s\n' "$ADDRS" | sed "s/^/        $C_DIM/; s/\$/$C_OFF/"
      fi
      ;;
  esac

  EXTERNAL=$(node_value ip_address_external)
  if [ -n "$EXTERNAL" ]; then
    ok "ip_address_external $EXTERNAL — the address it advertises"
  else
    bad "ip_address_external is empty — it is what the node puts in SIP and SDP" \
        "the public address of this host (the same one when there is no NAT)"
  fi

  # Kamailio holds 5060; sofia sits on 5070 and 5090 in the same network
  # namespace, so the three cannot collide.
  SIP_PORT=$(node_value sip_port)
  case "$SIP_PORT" in
    5060) ok "sip_port 5060 — kamailio, the node's front door" ;;
    '')   bad "sip_port is empty" "it is 5060" ;;
    5070|5090) bad "sip_port $SIP_PORT belongs to FreeSWITCH sofia; kamailio's is 5060" \
                   "set sip_port: \"5060\" in $VA_CONFIG" ;;
    *)    bad "sip_port $SIP_PORT — the node answers SIP on 5060" \
              "set sip_port: \"5060\" in $VA_CONFIG" ;;
  esac
  INT=$(yaml_section_value sip_interfaces port_internal)
  EXT=$(yaml_section_value sip_interfaces port_external)
  if [ -n "$INT" ] && [ "$INT" = "$EXT" ]; then
    bad "sofia's phone and carrier ports are both $INT — they share one network namespace" \
        "5070 for phones, 5090 for carriers"
  elif [ -n "$INT" ] && { [ "$INT" = "$SIP_PORT" ] || [ "$EXT" = "$SIP_PORT" ]; }; then
    bad "sofia ($INT/$EXT) collides with kamailio ($SIP_PORT)" \
        "kamailio 5060, sofia 5070 and 5090"
  elif [ -n "$INT" ]; then
    ok "sofia $INT (phones) / $EXT (carriers)"
  fi

  MOTHERSHIP=$(yaml_section_value mothership url)
  case "$MOTHERSHIP" in
    https://*) ok "mothership $MOTHERSHIP" ;;
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*)
      ok "mothership $MOTHERSHIP (plain HTTP, but it is loopback)" ;;
    '') warn "no mothership.url — this node is registered with nothing" \
             "add it to $VA_CONFIG, or install with VA_API_URL=…" ;;
    http://*) bad "mothership $MOTHERSHIP is plain HTTP — only loopback may be" \
                  "use https://, so the Account credential is not sent in the clear" ;;
    *)  bad "mothership.url is not a URL: $MOTHERSHIP" "for example https://cloud.voipappz.io" ;;
  esac
  case "$MOTHERSHIP" in
    https://*)
      if [ -f ./config/ca-bundle.pem ]; then
        ok "config/ca-bundle.pem — that mothership's certificate is pinned"
      fi ;;
  esac

  BROKER=$(yaml_section_value broker url)
  case "$BROKER" in
    '') bad "broker.url is empty — the node needs an external NATS broker to come up" \
            "nats://<host>:4222 in $VA_CONFIG" ;;
    nats://*|tls://*|ws://*|wss://*)
      ok "broker $(printf '%s' "$BROKER" | sed 's#://[^@/]*@#://<credential>@#')" ;;
    *)  bad "broker.url is not a NATS URL: $BROKER" "nats://<host>:4222" ;;
  esac
  # va.yaml is world-readable; ./.env is not. A broker credential belongs in
  # VA_NATS_URL_CREDENTIALED, which up.sh passes to the container as NATS_URL.
  case "$BROKER" in
    *://*@*) warn "the broker URL carries a credential, and $VA_CONFIG is world-readable" \
                  "keep the bare nats://host:4222 here and put the full URL in $VA_ENV_FILE as VA_NATS_URL_CREDENTIALED" ;;
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
    bad "$VA_CONFIG contains:$LEAKED" \
        "secrets belong in $VA_ENV_FILE (0600); the YAML is world-readable"
  fi
fi

# ── the ports ───────────────────────────────────────────────────────────────
# What the node owns on this machine. Nothing else — no database, no broker
# beyond broker.url. `--network host` means a port held by anything else is a
# node that starts and dies in an s6 restart loop.
step "The ports this node needs on this host"
if running; then
  ok "$NODE is already running — it holds these ports itself"
else
  OTHERS=$(docker ps --filter network=host --format '{{.Names}} {{.Image}}' 2>/dev/null |
    awk -v me="$NODE" '$2 ~ /va-crystal/ && $1 != me { print }' || true)
  if [ -n "$OTHERS" ]; then
    bad "another node container already owns this host's ports" \
        "stop it first: docker stop $(printf '%s' "$OTHERS" | head -1 | cut -d' ' -f1)"
    printf '%s\n' "$OTHERS" | sed "s/^/        $C_DIM/; s/\$/$C_OFF/"
  fi
  if command -v ss >/dev/null 2>&1; then
    LISTENERS=$(ss -H -lntu 2>/dev/null | awk '{ print $1, $5 }')
  elif command -v netstat >/dev/null 2>&1; then
    LISTENERS=$(netstat -lntu 2>/dev/null | awk '/^(tcp|udp)/ { proto = $1; sub(/[46]$/, "", proto); print proto, $4 }')
  else
    LISTENERS=""
    warn "neither ss nor netstat is here, so the ports could not be checked"
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
      bad "something else already holds:$BUSY" \
          "the node binds the host's ports directly; free them or stop what holds them"
    fi
  fi
fi

# ── the node that is running, if one is ─────────────────────────────────────
# Never a failure: this is the difference between an edit that is live and an
# edit that is still waiting for `make up`.
if running; then
  step "The node that is running right now"
  RUN_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$NODE" 2>/dev/null || true)
  if [ -n "${VA_VOIP_IMAGE:-}" ] && [ "$RUN_IMAGE" != "$VA_VOIP_IMAGE" ]; then
    warn "$NODE is running $RUN_IMAGE, not the $VA_VOIP_IMAGE above" \
         "restart it on the tag you verified: make up"
  else
    ok "$NODE is running $RUN_IMAGE"
  fi
  RUN_YAML=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/tmp/node.yaml"}}{{.Source}}{{end}}{{end}}' "$NODE" 2>/dev/null || true)
  CONFIG_ABS=$(cd "$(dirname "$VA_CONFIG")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$VA_CONFIG")")
  if [ -n "$RUN_YAML" ] && [ "$RUN_YAML" != "$CONFIG_ABS" ]; then
    warn "$NODE was started from $RUN_YAML, not the file just checked" \
         "restart it from this one: make up"
  elif [ -n "$RUN_YAML" ]; then
    ok "it is running the file just checked, mounted at /tmp/node.yaml"
  fi
fi

# ── the verdict ─────────────────────────────────────────────────────────────
# ONE LINE THAT SAYS WHAT TO DO. A count of green ticks is not an answer;
# "start it" and "it will not start" are.
printf '\n%s%s green%s · %s%s to look at%s · %s%s stopping this node%s\n' \
  "$C_GREEN" "$OKS" "$C_OFF" "$C_YELLOW" "$WARNS" "$C_OFF" "$C_RED" "$FAILS" "$C_OFF"
if [ "$FAILS" -eq 0 ]; then
  printf '%s✔ this node is ready%s  —  start it with: %smake up%s\n\n' \
    "$C_GREEN$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF"
else
  printf '%s✘ this node will not start%s  —  fix the %d red line(s) above, then run %smake verify%s again\n' \
    "$C_RED$C_BOLD" "$C_OFF" "$FAILS" "$C_BOLD" "$C_OFF" >&2
  printf '%s  the wizard writes both files for you: make setup%s\n\n' "$C_DIM" "$C_OFF" >&2
  exit 1
fi
