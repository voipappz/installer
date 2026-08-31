#!/usr/bin/env bash
# Two PBXs on one host, each the other's SIP trunk provider — assembled from a
# lab file and proven with a call in each direction.
#
#   tests/two-pbx.sh [tests/lab.yml]
#
# Reads the lab file (see tests/lab.yml.example), then, idempotently:
#   1. resolves each node's customer and environment on the mothership,
#   2. ensures its extensions exist (creating them, PATCHing the SIP password),
#   3. ensures the trunk objects: a type=sip provider pointing at the peer,
#      the customer's own number, and the DID mapping that number to an
#      extension when the peer's call arrives,
#   4. ensures each node's va.yaml admits the peer (sip_interfaces gateways)
#      and syncs kamailio's address table from it,
#   5. registers the callee, dials from the caller, and asserts BOTH ends:
#      sipp success on the caller, dialplan destination + answer on the callee.
#
# Credentials: each node's `account:` names a mode-0600 curl config holding
#   user = "email:password"
# — its customer's own Account, the one install.sh created the customer with.
# It reaches curl as a file, never argv. SIP passwords come from
# VA_LAB_SIP_PASSWORD_<ext>, defaulting to SipTest<ext>: lab peers on a
# private host, not production secrets.
set -Eeuo pipefail

LAB_FILE=${1:-tests/lab.yml}
[[ -f $LAB_FILE ]] || { echo "no lab file: $LAB_FILE (copy tests/lab.yml.example)" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }

# ── the lab file → n0_* / n1_* variables ─────────────────────────────────────
MOTHERSHIP=$(awk '$1=="mothership:"{print $2; exit}' "$LAB_FILE")
[[ -n $MOTHERSHIP ]] || die "the lab file names no mothership"
node_count=0
# shellcheck disable=SC2034  # consumed through the eval below
while IFS='|' read -r name container yaml account ip customer number extensions did_ext; do
  eval "n${node_count}_name=\$name n${node_count}_container=\$container \
        n${node_count}_yaml=\$yaml n${node_count}_account=\$account \
        n${node_count}_ip=\$ip \
        n${node_count}_customer=\$customer n${node_count}_number=\$number \
        n${node_count}_extensions=\$extensions n${node_count}_did_ext=\$did_ext"
  node_count=$((node_count + 1))
done < <(awk '
  /^[[:space:]]*- name:/ { if (n["name"] != "") emit(); delete n }
  /^[[:space:]]*(- )?[a-z_]+:/ {
    line = $0; sub(/^[[:space:]]*(- )?/, "", line)
    key = line; sub(/:.*/, "", key)
    val = line; sub(/^[a-z_]+:[[:space:]]*/, "", val); gsub(/"/, "", val)
    n[key] = val
  }
  function emit() { printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
    n["name"], n["container"], n["yaml"], n["account"], n["ip"], n["customer"],
    n["number"], n["extensions"], n["did_extension"] }
  END { if (n["name"] != "") emit() }' "$LAB_FILE")
[[ $node_count -eq 2 ]] || die "the lab file must define exactly two nodes (got $node_count)"
for i in 0 1; do
  for f in name container yaml account ip customer number extensions did_ext; do
    v=$(eval "printf %s \"\$n${i}_$f\"")
    [[ -n $v ]] || die "node $i is missing '$f' in $LAB_FILE"
  done
  # ~ in paths, expanded here rather than by the shell that read them
  eval "n${i}_yaml=\${n${i}_yaml/#~/$HOME} n${i}_account=\${n${i}_account/#~/$HOME}"
  acct=$(eval "printf %s \"\$n${i}_account\"")
  [[ -f $acct ]] || die "node $i: account curl config not found: $acct"
done

api() { # node-index method path [curl args…] — the NODE'S OWN Account
  curl --config "$(eval "printf %s \"\$n${1}_account\"")" \
    --fail-with-body --silent --show-error \
    --header 'Accept: application/json' --connect-timeout 10 --max-time 60 \
    --request "$2" --url "$MOTHERSHIP/api$3" "${@:4}"
}

sip_password() { # ext
  eval "printf %s \"\${VA_LAB_SIP_PASSWORD_$1:-SipTest$1}\""
}

# docker exec with the env the node's va.yaml moved (a second node's CLI needs
# the moved RPC/node/FS ports; `docker exec` sees only the original env)
node_exec() { # node-index cmd…
  local yaml args
  yaml=$(eval "printf %s \"\$n${1}_yaml\"")
  args=()
  while IFS=: read -r k v; do
    k=$(printf %s "$k" | tr -d ' '); v=$(printf %s "$v" | tr -d ' "')
    case $k in
      PORT)                 args+=(-e "VA_NODE_PORT=$v") ;;
      FREESWITCH_PORT)      args+=(-e "VA_FREESWITCH_PORT=$v") ;;
      VA_KAMAILIO_TCP_PORT) args+=(-e "VA_KAMAILIO_TCP_PORT=$v" -e "VA_KAMAILIO_RPC_URL=http://127.0.0.1:$v/RPC") ;;
    esac
  done < <(sed -n '/^env:/,$p' "$yaml" | tail -n +2 | grep -E '^[[:space:]]+[A-Z_]+:')
  docker exec "${args[@]}" "$(eval "printf %s \"\$n${1}_container\"")" "${@:2}"
}

echo "── the mothership side, per node"
for i in 0 1; do
  name=$(eval "printf %s \"\$n${i}_name\"")
  customer=$(eval "printf %s \"\$n${i}_customer\"")

  env_json=$(api "$i" GET /environments | jq '.[0]')
  env_uuid=$(jq -r '.uuid // empty' <<<"$env_json")
  [[ -n $env_uuid ]] || die "$name: the Account for '$customer' sees no environment (Customer::Init did not run?)"
  domain=$(jq -r '.domain // .profile.domain // empty' <<<"$env_json")
  [[ -n $domain ]] || die "$name: environment $env_uuid has no domain"

  user_uuid=$(api "$i" GET /users | jq -r --arg e "$env_uuid" '[.[] | select((.environment_uuid // $e) == $e)] | .[0].uuid // empty')
  [[ -n $user_uuid ]] || die "environment $env_uuid has no user to own extensions"

  exts_json=$(api "$i" GET /extensions)
  for ext in $(eval "printf %s \"\$n${i}_extensions\""); do
    ext_uuid=$(jq -r --arg u "$ext" --arg e "$env_uuid" \
      '[.[] | select((.environment_uuid // $e) == $e and (.username | startswith($u)))] | .[0].uuid // empty' <<<"$exts_json")
    if [[ -z $ext_uuid ]]; then
      ext_uuid=$(api "$i" POST /extensions \
        --data-urlencode "username=$ext" --data-urlencode "name=lab-$ext" \
        --data-urlencode enabled=true --data-urlencode "environment_uuid=$env_uuid" \
        --data-urlencode "user_uuid=$user_uuid" | jq -r .uuid)
      pass "$name: extension $ext created"
    fi
    api "$i" PATCH "/extensions/$ext_uuid" --data-urlencode "password=$(sip_password "$ext")" >/dev/null
  done
  pass "$name: customer $customer, domain $domain, extensions $(eval "printf %s \"\$n${i}_extensions\"") ready"
  eval "n${i}_env_uuid=\$env_uuid n${i}_domain=\$domain"
done

echo "── the trunk objects (provider toward the peer, own number, DID)"
for i in 0 1; do
  peer=$((1 - i))
  name=$(eval "printf %s \"\$n${i}_name\"")
  env_uuid=$(eval "printf %s \"\$n${i}_env_uuid\"")
  peer_ip=$(eval "printf %s \"\$n${peer}_ip\"")
  peer_name=$(eval "printf %s \"\$n${peer}_name\"")
  number=$(eval "printf %s \"\$n${i}_number\"")
  did_ext=$(eval "printf %s \"\$n${i}_did_ext\"")

  # the provider is matched by its ADDRESS — the peer's IP — not by name
  providers=$(api "$i" GET /providers)
  prov_uuid=$(jq -r --arg a "$peer_ip" --arg e "$env_uuid" \
    '[.[] | select((.environment_uuid // $e) == $e and .type == "sip" and .profile.address == $a)] | .[0].uuid // empty' <<<"$providers")
  if [[ -z $prov_uuid ]]; then
    tariff_uuid=$(api "$i" GET /tariffs | jq -r --arg e "$env_uuid" '[.[] | select((.environment_uuid // $e) == $e)] | .[0].uuid // empty')
    [[ -n $tariff_uuid ]] || die "$name: no tariff to attach the provider to"
    prov_uuid=$(api "$i" POST /providers \
      --data-urlencode "name=trunk-$name-to-$peer_name" --data-urlencode type=sip \
      --data-urlencode enabled=true --data-urlencode "environment_uuid=$env_uuid" \
      --data-urlencode "tariff_uuid=$tariff_uuid" \
      --data-urlencode "profile[address]=$peer_ip" --data-urlencode 'profile[port]=5060' \
      --data-urlencode 'profile[transport]=udp' | jq -r .uuid)
    pass "$name: provider toward $peer_name created"
  fi

  api "$i" GET /numbers | jq -e --arg n "$number" --arg e "$env_uuid" \
    '[.[] | select((.environment_uuid // $e) == $e and .number == $n)] | length == 1' >/dev/null ||
    api "$i" POST /numbers --data-urlencode "number=$number" \
      --data-urlencode "environment_uuid=$env_uuid" >/dev/null

  # The customer's number is also its outbound caller ID — without this the
  # environment profile has none, the leg vars render empty and the callee
  # sees caller "0" (GenerateCallerIdNumber falls through to nothing).
  api "$i" GET "/environments/$env_uuid" | jq -e --arg n "$number" \
    '.profile.caller_id_number == $n' >/dev/null ||
    api "$i" PATCH "/environments/$env_uuid" \
      --data-urlencode "profile[caller_id_number]=$number" >/dev/null

  ext_uuid=$(api "$i" GET /extensions | jq -r --arg u "$did_ext" --arg e "$env_uuid" \
    '[.[] | select((.environment_uuid // $e) == $e and (.username | startswith($u)))] | .[0].uuid // empty')
  api "$i" GET /dids | jq -e --arg n "$number" --arg e "$env_uuid" \
    '[.[] | select((.environment_uuid // $e) == $e and .number == $n)] | length >= 1' >/dev/null ||
    api "$i" POST /dids --data-urlencode "number=$number" --data-urlencode type=dst \
      --data-urlencode bridge_type=extension --data-urlencode "bridge_uuid=$ext_uuid" \
      --data-urlencode "environment_uuid=$env_uuid" \
      --data-urlencode "provider_uuid=$prov_uuid" >/dev/null
  pass "$name: trunk to $peer_name ($prov_uuid), number $number → $did_ext"
  eval "n${i}_prov_uuid=\$prov_uuid"
done

echo "── the node side (va.yaml gateways + kamailio address table)"
for i in 0 1; do
  peer=$((1 - i))
  name=$(eval "printf %s \"\$n${i}_name\"")
  yaml=$(eval "printf %s \"\$n${i}_yaml\"")
  entry="$(eval "printf %s \"\$n${peer}_ip\"")/32|$(eval "printf %s \"\$n${i}_prov_uuid\"")"
  if ! grep -qF "$entry" "$yaml"; then
    grep -q '^\s*gateways:' "$yaml" || die "$name: $yaml has no gateways: key under sip_interfaces — add one, then rerun"
    # append under the existing gateways: key, matching its list indentation,
    # WITHOUT replacing the file: it is bind-mounted into the running node
    indent=$(awk '/^[[:space:]]*gateways:/{match($0,/^[[:space:]]*/); printf "%*s", RLENGTH+2, ""; exit}' "$yaml")
    tmp=$(mktemp) && awk -v e="$entry" -v ind="$indent" \
      '{print} /^[[:space:]]*gateways:/ && !done {printf "%s- '\''%s'\''\n", ind, e; done=1}' \
      "$yaml" >"$tmp" && cat "$tmp" >"$yaml" && rm -f "$tmp"
    pass "$name: gateways entry added"
  fi
  node_exec "$i" voipappz sbc egress sync >/dev/null || die "$name: sbc egress sync failed"
  pass "$name: peer admitted ($entry)"
done

echo "── a call in each direction"
run_call() { # caller-index callee-index
  local ci=$1 ce=$2
  local caller callee caller_ip callee_ip caller_dom callee_dom dial ans
  caller=$(eval "printf %s \"\$n${ci}_extensions\""); caller=${caller##* }   # last listed
  callee=$(eval "printf %s \"\$n${ce}_did_ext\"")
  caller_ip=$(eval "printf %s \"\$n${ci}_ip\"");  callee_ip=$(eval "printf %s \"\$n${ce}_ip\"")
  caller_dom=$(eval "printf %s \"\$n${ci}_domain\""); callee_dom=$(eval "printf %s \"\$n${ce}_domain\"")
  dial=$(eval "printf %s \"\$n${ce}_number\"")

  node_exec "$ce" sh -c "cd /tmp &&
    printf 'SEQUENTIAL\n$callee_dom;$callee;$(sip_password "$callee")\n' > lab-reg.csv &&
    sipp $callee_ip:5060 -i $callee_ip -sf /etc/sipp/register.xml -inf lab-reg.csv \
      -m 1 -r 1 -timeout 20 -au $callee -ap '$(sip_password "$callee")' -p 5062 -nostdin" \
      >/dev/null 2>&1 || die "callee $callee failed to register"
  node_exec "$ce" sh -c "cd /tmp && nohup sipp -sf /etc/sipp/uas-answer.xml -nd \
    -i $callee_ip -p 5062 -mp 6190 -m 1 -timeout 60 -nostdin >lab-uas.log 2>&1 &" 
  sleep 2
  node_exec "$ci" sh -c "cd /tmp &&
    printf 'SEQUENTIAL\n$caller_dom;$caller;$(sip_password "$caller")\n' > lab-reg.csv &&
    printf 'SEQUENTIAL\n$caller_dom;$caller;$(sip_password "$caller");$dial\n' > lab-call.csv &&
    sipp $caller_ip:5060 -i $caller_ip -sf /etc/sipp/register.xml -inf lab-reg.csv \
      -m 1 -r 1 -timeout 20 -au $caller -ap '$(sip_password "$caller")' -p 5073 -nostdin >/dev/null 2>&1 &&
    sipp $caller_ip:5060 -i $caller_ip -sf /etc/sipp/call.xml -inf lab-call.csv \
      -m 1 -r 1 -timeout 40 -au $caller -ap '$(sip_password "$caller")' -p 5073 -mp 6090 -nostdin" \
      >/dev/null 2>&1 || die "caller $caller → $dial: sipp reported failure"
  sleep 2
  ans=$(docker logs --since 2m "$(eval "printf %s \"\$n${ce}_container\"")" 2>&1 |
    grep -aE "\"destination\",\"value\":\"$callee\"|user_to..:..$callee" | head -1)
  [[ -n $ans ]] || die "callee node never routed $dial to $callee (check its dialplan log)"
  pass "$caller@$(eval "printf %s \"\$n${ci}_name\"") → $dial → $callee@$(eval "printf %s \"\$n${ce}_name\"") answered"
}
run_call 0 1
run_call 1 0

printf '\n\033[1mtwo-pbx lab green\033[0m — trunk calls proven in both directions\n'
