#!/usr/bin/env bash
# Unit tests for install.sh's pure functions and argument validation.
#
#   tests/unit.sh
#
# The integration test proves the whole installer on a clean host; this proves
# the small functions in isolation, in a second, with no Docker and no network.
# Functions are lifted out of install.sh by name (awk between `name() {` and
# the closing `}`), so they are the real code, not a copy.
# The checks are deliberately single-quoted expressions handed to eval.
# shellcheck disable=SC2016
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/install.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

lift() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$INSTALLER"; }

# ── argument validation: the script must refuse before doing anything ────────
printf '\n── argument validation\n'
refuses() {  # label, expected message, env...
  local label=$1 msg=$2; shift 2
  local out
  out=$(env "$@" sh "$INSTALLER" </dev/null 2>&1 || true)
  if grep -Fq -- "$msg" <<<"$out"; then ok "$label"; else bad "$label: got '$out'"; fi
}
refuses 'START must be 0 or 1'                    'START must be 0 or 1'                 START=2
refuses 'VA_REGISTER must be 0 or 1'              'VA_REGISTER must be 0 or 1'           VA_REGISTER=yes
refuses 'INSTALL_DIR must be absolute'            'INSTALL_DIR must be an absolute'      INSTALL_DIR=relative/dir
refuses 'VA_IMAGE_SOURCE must be a known source'  'VA_IMAGE_SOURCE must be dockerhub, s3 or archive' VA_IMAGE_SOURCE=ftp
refuses 'VA_IMAGE_SOURCE=archive needs an archive' 'needs VA_IMAGE_ARCHIVE'              VA_IMAGE_SOURCE=archive
refuses 'VA_IMAGE_ARCHIVE must be absolute or a URL' 'absolute path or an http(s) URL'   VA_IMAGE_ARCHIVE=rel.tar.gz
refuses 'VA_IMAGE_ARCHIVE must be readable'       'not a readable file'                  VA_IMAGE_ARCHIVE=/nonexistent/x.tar.gz

# ── the lifted functions ─────────────────────────────────────────────────────
printf '\n── registry_of\n'
LIB="$TMP/lib.sh"
{ printf '%s\n' 'die() { printf "die: %s\n" "$*" >&2; exit 1; }'
  echo 'say() { :; }'
  echo 'fs_cmd() { "$@"; }'
  lift registry_of; lift validate_scalar; lift yaml_api_url; lift yaml_broker_url; lift set_yaml_section_url
} > "$LIB"
# shellcheck disable=SC1090
source "$LIB"
check 'Docker Hub reference has no registry'         '[[ $(registry_of nirlevi/va-crystal:node) == "" ]]'
check 'bare name has no registry'                    '[[ $(registry_of alpine) == "" ]]'
check 'host with a dot is a registry'                '[[ $(registry_of ghcr.io/kamailio/kamailio:6) == ghcr.io ]]'
check 'host with a port is a registry'               '[[ $(registry_of localhost:5001/va/stack:test) == localhost:5001 ]]'
check 'localhost is a registry'                      '[[ $(registry_of localhost/x:y) == localhost ]]'

printf '\n── validate_scalar\n'
check 'plain value passes'                           'validate_scalar X "https://cloud.voipappz.io" 2>/dev/null'
check 'a quote is refused'                           '! ( validate_scalar X "it'"'"'s" ) 2>/dev/null'
check 'a newline is refused'                         '! ( validate_scalar X "$(printf "a\nb")" ) 2>/dev/null'
check 'a control character is refused'               '! ( validate_scalar X "$(printf "a\tb")" ) 2>/dev/null'

printf '\n── va.yaml url readers and writer\n'
# shellcheck disable=SC2034  # read by the lifted functions
WORK_DIR="$TMP"; INSTALL_DIR="$TMP"; : "$WORK_DIR" "$INSTALL_DIR"; mkdir -p "$TMP/config"
VA_YAML="$TMP/config/va.yaml"
cat > "$VA_YAML" <<'Y'
organization:
  name: X
mothership:
  url: 'https://old.example'
broker:
  url: ""
nodes:
- uuid: 11111111-1111-4111-8111-111111111111
Y
check 'yaml_api_url reads the quoted value'          '[[ $(yaml_api_url) == https://old.example ]]'
check 'yaml_broker_url treats "" as empty'           '[[ -z $(yaml_broker_url) ]]'
set_yaml_section_url mothership VA_API_URL https://new.example
check 'set_yaml_section_url replaces in place'       '[[ $(yaml_api_url) == https://new.example ]] && [[ $(grep -c "^mothership:" "$VA_YAML") == 1 ]]'
set_yaml_section_url broker VA_NATS_URL nats://broker.example:4222
check 'set_yaml_section_url fills an empty value'    '[[ $(yaml_broker_url) == nats://broker.example:4222 ]]'
check 'other sections are untouched'                 'grep -q "^- uuid: 11111111" "$VA_YAML" && grep -q "^  name: X" "$VA_YAML"'
sed -i '/^broker:/,/^  url:/d' "$VA_YAML"
set_yaml_section_url broker VA_NATS_URL nats://added.example:4222
check 'set_yaml_section_url appends a missing section' '[[ $(yaml_broker_url) == nats://added.example:4222 ]]'
check 'the writer refuses a quoted value'            '! ( set_yaml_section_url broker VA_NATS_URL "nats://x'"'"'y" ) 2>/dev/null'

# ── the secret crosses into docker on stdin, never as an argument ────────────
printf '\n── docker_with_authorization\n'
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/docker" <<'D'
#!/bin/sh
printf 'env=%s args=%s\n' "${VA_API_AUTHORIZATION:-<unset>}" "$*"
D
chmod +x "$FAKEBIN/docker"
{ echo 'DOCKER_AS_ROOT=0'; lift docker_with_authorization; } > "$TMP/auth.sh"
# shellcheck disable=SC1091
source "$TMP/auth.sh"
out=$(PATH="$FAKEBIN:$PATH" VA_API_AUTHORIZATION='Basic c2VjcmV0' docker_with_authorization run --rm img node register)
check 'the container sees the authorization in its environment' '[[ $out == *"env=Basic c2VjcmV0"* ]]'
check 'the authorization is not a docker argument'             '[[ $out != *"args=*c2VjcmV0*"* ]] && [[ $out == *"args=run --rm img node register"* ]]'


# ── customer resolution against a fake mothership API ────────────────────────
# The live MTN install found this: a root Account sees every customer, so the
# count-based fallback cannot pick one. resolve_customer now reads the
# Account's own customer_uuid first. The API is faked with a `curl` on PATH
# that serves canned responses (like the fake `docker` above) and logs every
# request, so precedence can be proven by what was NOT asked for.
printf '\n── resolve_customer / account_customer_uuid\n'
cat > "$FAKEBIN/curl" <<'C'
#!/bin/sh
# Fake curl for the unit tests. Understands the flags api_request uses,
# serves $FAKE_API/<METHOD><slugged path>, logs the request, and prints the
# HTTP status like --write-out '%{http_code}'. A route whose status is FAIL
# exits like a transport error so api_request returns non-zero.
method=GET; out=/dev/null; url=""; data=""; wants_config=0
while [ $# -gt 0 ]; do
  case $1 in
    --config) [ "${2:-}" = "-" ] && wants_config=1; shift 2 ;;
    --request) method=$2; shift 2 ;;
    --output) out=$2; shift 2 ;;
    --url) url=$2; shift 2 ;;
    --data-urlencode) data="$data $2"; shift 2 ;;
    --write-out|--connect-timeout|--max-time) shift 2 ;;
    *) shift ;;
  esac
done
[ "$wants_config" = "0" ] || cat >> "$FAKE_API/config.log"
path=${url#*/api}
printf '%s %s%s\n' "$method" "$path" "$data" >> "$FAKE_API/requests.log"
route="$FAKE_API/$method$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')"
if [ -f "$route" ]; then
  status=$(head -1 "$route")
  [ "$status" != "FAIL" ] || { echo "curl: (7) failed to connect" >&2; exit 7; }
  tail -n +2 "$route" > "$out"
else
  status=404
  : > "$out"
fi
printf '%s' "$status"
C
chmod +x "$FAKEBIN/curl"

# The real functions, with only the installer's own helpers stubbed.
API_LIB="$TMP/api-lib.sh"
{ printf '%s\n' 'die() { printf "die: %s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'say() { printf "say: %s\n" "$*"; }'
  printf '%s\n' 'fs_cmd() { "$@"; }'
  printf '%s\n' 'prepare_install_dir() { :; }'
  printf '%s\n' 'ask() { REPLY=${FAKE_REPLY:-}; }'
  printf '%s\n' ': "${API_ROOT:=http://fake.invalid/api}"'
  printf '%s\n' ': "${VA_API_AUTHORIZATION:=Basic ZmFrZS10ZXN0}"'
  printf '%s\n' ': "${NODE_UUID:=11111111-1111-4111-8111-111111111111}"'
  printf '%s\n' ': "${ACCOUNT_EMAIL:=}" "${VA_CUSTOMER_UUID:=}" "${VA_CUSTOMER_NAME:=}"'
  printf '%s\n' ': "${CA_BUNDLE:=}" "${PINNED:=0}" "${SELECTED_CUSTOMER_UUID:=}"'
  lift api_request; lift api_error; lift load_customers; lift account_customer_uuid
  lift customer_by_uuid; lift customer_by_name; lift link_customer
  lift create_customer; lift resolve_customer
} > "$API_LIB"
cat > "$TMP/resolve.sh" <<'R'
set -eu
. "$API_LIB"
API_BODY_FILE=$(mktemp "$FAKE_API/body.XXXXXX")
API_STATUS=""; API_BODY=""; CUSTOMERS_JSON=""
: "${PROVISIONING_GUARD:=$FAKE_API/.customer-provisioning-incomplete}"
resolve_customer
printf 'SELECTED=%s\n' "$SELECTED_CUSTOMER_UUID"
R

NODE=11111111-1111-4111-8111-111111111111
OWN=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
OTHER=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
THIRD=cccccccc-cccc-4ccc-8ccc-cccccccccccc
ACCOUNT=dddddddd-dddd-4ddd-8ddd-dddddddddddd
api_n=0
api_reset() { api_n=$((api_n + 1)); FAKE_API="$TMP/api.$api_n"; mkdir -p "$FAKE_API"; : > "$FAKE_API/requests.log"; }
route() {  # METHOD PATH STATUS, body on stdin
  local key
  key=$1$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')
  { printf '%s\n' "$3"; cat; } > "$FAKE_API/$key"
}
three_customers() {
  route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":null},
 {"uuid":"$OTHER","name":"Other","enabled":true,"node_uuid":null},
 {"uuid":"$THIRD","name":"Third","enabled":true,"node_uuid":null}]
J
}
account_search() {  # body = the /accounts search result
  route GET /accounts 200
}
resolve() {  # extra env assignments
  CASE_STATUS=0
  CASE_OUT=$(env FAKE_API="$FAKE_API" API_LIB="$API_LIB" PATH="$FAKEBIN:$PATH" \
    NODE_UUID="$NODE" "$@" sh "$TMP/resolve.sh" 2>&1) || CASE_STATUS=$?
  : "$CASE_OUT" "$CASE_STATUS"   # both are read by the check expressions below
}

# (a) nothing named: the Account's own customer wins over the customer count.
api_reset; three_customers
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","email":"ops@acme.test","customer_uuid":"$OWN"}
J
route PATCH "/customers/$OWN" 200 <<J
{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'account.customer_uuid is used when nothing is named' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"SELECTED=$OWN"* ]] && [[ $CASE_OUT == *"the Account'"'"'s own customer is $OWN"* ]]'
check 'the account is looked up by an exact email search' \
  'grep -Fq "GET /accounts search[email]=ops@acme.test" "$FAKE_API/requests.log"'
check 'the own customer is linked to this node' \
  'grep -Fq "PATCH /customers/$OWN node_uuid=$NODE" "$FAKE_API/requests.log"'
check 'three visible customers no longer end the install' '[[ $CASE_OUT != *"sees 3 customers"* ]]'

# (b) an explicit selector still wins over account.customer_uuid.
api_reset; three_customers
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"$OWN"}
J
route PATCH "/customers/$OTHER" 200 <<J
{"uuid":"$OTHER","name":"Other","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test VA_CUSTOMER_UUID="$OTHER"
check 'VA_CUSTOMER_UUID wins over the Account customer' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"SELECTED=$OTHER"* ]]'
check 'a named customer never asks for the Account record' \
  '! grep -q "/accounts" "$FAKE_API/requests.log"'

api_reset; three_customers
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"$OWN"}
J
route PATCH "/customers/$THIRD" 200 <<J
{"uuid":"$THIRD","name":"Third","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test VA_CUSTOMER_NAME=Third
check 'VA_CUSTOMER_NAME wins over the Account customer' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"SELECTED=$THIRD"* ]] && ! grep -q "/accounts" "$FAKE_API/requests.log"'

# (c) the API search matches substrings; only an exact, single match counts.
api_reset; three_customers
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"noc-ops@acme.test","customer_uuid":"$OWN"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"$OWN"}
J
route PATCH "/customers/$OWN" 200 <<J
{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'a substring email match is not the Account' \
  '[[ $CASE_STATUS != 0 ]] && [[ $CASE_OUT == *"sees 3 customers"* ]]'
check 'a substring match never reads that account record' \
  '! grep -Fq "GET /accounts/$ACCOUNT" "$FAKE_API/requests.log"'

api_reset; three_customers
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"},
 {"uuid":"$OTHER","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"$OWN"}
J
route PATCH "/customers/$OWN" 200 <<J
{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'two accounts with the same email are ambiguous, not a match' \
  '[[ $CASE_STATUS != 0 ]] && [[ $CASE_OUT == *"sees 3 customers"* ]]'

# (d) best-effort: no email (Account token) and an API that cannot answer both
# fall through to the old behaviour instead of failing the install.
api_reset
route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":null}]
J
route PATCH "/customers/$OWN" 200 <<J
{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=
check 'an Account token (no email) falls through to the single customer' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"SELECTED=$OWN"* ]]'
check 'no email means no /accounts request at all' \
  '! grep -q "/accounts" "$FAKE_API/requests.log"'

api_reset
route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":null}]
J
route PATCH "/customers/$OWN" 200 <<J
{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test   # /accounts is unrouted: HTTP 404
check 'a mothership without /accounts still installs' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"SELECTED=$OWN"* ]]'

api_reset
route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":null}]
J
route GET /accounts FAIL <<'J'
J
route PATCH "/customers/$OWN" 200 <<J
{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'an unreachable /accounts is not fatal' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"SELECTED=$OWN"* ]]'

api_reset; three_customers
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<'J'
{"uuid":"dddddddd-dddd-4ddd-8ddd-dddddddddddd"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'an account with no customer_uuid falls through' \
  '[[ $CASE_STATUS != 0 ]] && [[ $CASE_OUT == *"sees 3 customers"* ]]'

api_reset; three_customers
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"99999999-9999-4999-8999-999999999999"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'an account customer this Account cannot see falls through' \
  '[[ $CASE_STATUS != 0 ]] && [[ $CASE_OUT == *"sees 3 customers"* ]]'

# (e) the Account's own customer is still only a customer: every refusal holds.
api_reset
route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":false,"node_uuid":null},
 {"uuid":"$OTHER","name":"Other","enabled":true,"node_uuid":null}]
J
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"$OWN"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'a disabled Account customer is refused' \
  '[[ $CASE_STATUS != 0 ]] && [[ $CASE_OUT == *"customer $OWN is disabled"* ]]'
check 'a disabled customer is never linked' '! grep -q "^PATCH" "$FAKE_API/requests.log"'

api_reset
route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":false,"node_uuid":null}]
J
resolve ACCOUNT_EMAIL= VA_CUSTOMER_UUID="$OWN"
check 'a disabled named customer is refused too' \
  '[[ $CASE_STATUS != 0 ]] && [[ $CASE_OUT == *"customer $OWN is disabled"* ]]'

api_reset
route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$OTHER"}]
J
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"$OWN"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'an Account customer homed on another node is not moved' \
  '[[ $CASE_STATUS != 0 ]] && [[ $CASE_OUT == *"refusing to move it"* ]]'

api_reset
route GET /customers 200 <<J
[{"uuid":"$OWN","name":"Own","enabled":true,"node_uuid":"$NODE"}]
J
route GET /accounts 200 <<J
[{"uuid":"$ACCOUNT","email":"ops@acme.test"}]
J
route GET "/accounts/$ACCOUNT" 200 <<J
{"uuid":"$ACCOUNT","customer_uuid":"$OWN"}
J
resolve ACCOUNT_EMAIL=ops@acme.test
check 'an Account customer already on this node is idempotent' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"already linked to this node"* ]]'

# No customers at all: the account lookup cannot invent one, and the old
# create path still runs.
api_reset
route GET /customers 200 <<'J'
[]
J
route POST /customers 201 <<J
{"uuid":"$THIRD","name":"Fresh","enabled":true,"node_uuid":"$NODE"}
J
resolve ACCOUNT_EMAIL=ops@acme.test FAKE_REPLY=Fresh
check 'an empty customer list still creates one' \
  '[[ $CASE_STATUS == 0 ]] && [[ $CASE_OUT == *"SELECTED=$THIRD"* ]] && grep -Fq "POST /customers name=Fresh" "$FAKE_API/requests.log"'

# ── the Account email survives; the password does not ────────────────────────
printf '\n── set_account_authorization\n'
{ printf '%s\n' 'die() { printf "die: %s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'say() { printf "say: %s\n" "$*"; }'
  printf '%s\n' 'ask() { die "set_account_authorization must not prompt when the login is given"; }'
  printf '%s\n' 'REPLY=""; ACCOUNT_EMAIL=""; ACCOUNT_EMAIL_INPUT=""; ACCOUNT_PASSWORD_INPUT=""; ACCOUNT_BASIC_INPUT=""'
  lift set_account_authorization
  printf '%s\n' 'set_account_authorization'
  printf '%s\n' 'printf "ACCOUNT_EMAIL=%s\n" "$ACCOUNT_EMAIL"'
  printf '%s\n' 'printf "AUTHORIZATION=%s\n" "$VA_API_AUTHORIZATION"'
  printf '%s\n' 'printf "EMAIL_SET=%s\n" "${VA_API_EMAIL+yes}"'
  printf '%s\n' 'printf "PASSWORD_SET=%s\n" "${VA_API_PASSWORD+yes}"'
  printf '%s\n' 'set | LC_ALL=C grep -F "S3cret-Pa55w0rd" > "$FAKE_API/leak" || true'
} > "$TMP/account.sh"
api_reset
CASE_OUT=$(env FAKE_API="$FAKE_API" VA_API_EMAIL=ops@acme.test VA_API_PASSWORD='S3cret-Pa55w0rd' \
  sh "$TMP/account.sh" 2>&1)
check 'the Account email is kept for the account lookup' '[[ $CASE_OUT == *"ACCOUNT_EMAIL=ops@acme.test"* ]]'
check 'the authorization is the Basic value of email:password' \
  '[[ $CASE_OUT == *"AUTHORIZATION=Basic $(printf "%s" "ops@acme.test:S3cret-Pa55w0rd" | base64 | tr -d "\n")"* ]]'
check 'VA_API_EMAIL is unset afterwards'    '[[ $CASE_OUT == *"EMAIL_SET="* ]] && [[ $CASE_OUT != *"EMAIL_SET=yes"* ]]'
check 'VA_API_PASSWORD is unset afterwards' '[[ $CASE_OUT != *"PASSWORD_SET=yes"* ]]'
check 'no variable still holds the password' '[[ ! -s $FAKE_API/leak ]]'

# ── the shipped examples ─────────────────────────────────────────────────────
printf '\n── va.yaml.example and .env.example\n'
EX="$ROOT/va.yaml.example"; : "$EX"
check 'va.yaml.example exists'                       '[[ -f $EX ]]'
check 'it is a node, not the app'                    'grep -q "^  type: switch" "$EX"'
# The node's own health probes these two ports (node_env.cr constants); an
# example on other ports produces a node that fails health on a port it never
# bound, which is exactly how CI found this.
check 'sofia internal port is the one health probes' 'grep -q "port_internal: \"5070\"" "$EX"'
check 'sofia external port is the one health probes' 'grep -q "port_external: \"5090\"" "$EX"'
check 'kamailio keeps 5060'                          'grep -q "sip_port: \"5060\"" "$EX"'
check 'it names a mothership and a broker'           'grep -q "^mothership:" "$EX" && grep -q "^broker:" "$EX"'
check 'it carries no customers block'                '! grep -q "^customers:" "$EX"'
check '.env.example exists'                          '[[ -f $ROOT/.env.example ]]'
check '.env.example holds no real secret'            '! grep -Eq "^[A-Z_]*(PASSWORD|SECRET|KEY|TOKEN)=[A-Za-z0-9+/]{12,}" "$ROOT/.env.example"'
check '.env.example is the answer file: mothership + login' 'grep -q "^VA_API_URL=" "$ROOT/.env.example" && grep -q "^VA_API_EMAIL=" "$ROOT/.env.example" && grep -q "^VA_API_PASSWORD=" "$ROOT/.env.example"'
check '.env.example picks the image source'          'grep -q "^VA_IMAGE_SOURCE=" "$ROOT/.env.example"'
check 'a real .env is never committed'               'git -C "$ROOT" check-ignore -q .env'
# The answer file is read before anything else, and the environment wins.
check 'the installer loads ./.env'                   'grep -q "VA_ENV_FILE=./.env" "$ROOT/install.sh"'
check 'the installer runs the node with docker run'  'grep -q "docker_cmd run -d --name va-voip" "$ROOT/install.sh"'
check 'the installer no longer needs Compose'        '! grep -qE "compose (up|down|ps|config|version)" "$ROOT/install.sh"'
check 'the installer no longer extracts /stack'      '! grep -q "stack/." "$ROOT/install.sh"'
printf '\n'
if ((fails == 0)); then printf '\033[1munit: all green\033[0m\n'; else printf '\033[1m!! %d unit failure(s)\033[0m\n' "$fails"; exit 1; fi
