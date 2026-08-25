#!/usr/bin/env bash
# Real installer integration test. It boots the complete public mothership
# app/storage environment and talks to its actual Ruby API and Customer::Init.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOTHERSHIP_DIR=${1:-}
[[ -n $MOTHERSHIP_DIR && -f $MOTHERSHIP_DIR/docker-compose.yaml ]] || {
  echo 'usage: tests/test-install.sh /path/to/mothership' >&2
  exit 2
}
MOTHERSHIP_DIR=$(cd "$MOTHERSHIP_DIR" && pwd)

: "${VA_REGISTRY_USER:?VA_REGISTRY_USER is required}"
: "${VA_REGISTRY_TOKEN:?VA_REGISTRY_TOKEN is required}"

RUN_ROOT=$(mktemp -d "${RUNNER_TEMP:-/tmp}/voipappz-installer.XXXXXX")
NODE_DIR="$RUN_ROOT/node"
LOG_DIR="$RUN_ROOT/logs"
BOOT_CONFIG="$RUN_ROOT/node.yaml"
DOCKER_AUTH_DIR="$RUN_ROOT/docker-auth"
ONBOARD_OUTPUT="$RUN_ROOT/onboard.out"
mkdir -p "$LOG_DIR"

NODE_UUID=11111111-1111-4111-8111-111111111111
NODE_SIP_UUID=22222222-2222-4222-8222-222222222222
APP_UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
APP_SIP_UUID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
OTHER_NODE_UUID=33333333-3333-4333-8333-333333333333
GATEWAY_UUID=44444444-4444-4444-8444-444444444444
API_URL=http://127.0.0.1:5000
ACCOUNT_EMAIL=installer-ci@example.invalid
ACCOUNT_PASSWORD='Vpz-Installer-CI-2026!'
BASIC_VALUE=""
BASIC_AUTH=""
LAST_LOG=""
MOTHERSHIP_UP=0
NODE_UP=0
BROKER_UP=0

die() {
  printf '\nnot ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

diagnostics() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  echo '--- docker containers' >&2
  docker ps -a >&2 || true
  for container in va-postgres va-db-init va-app va-nats va-minio va-kong va-ingress va-voip; do
    docker inspect "$container" >/dev/null 2>&1 || continue
    echo "--- $container (last 80 lines)" >&2
    docker logs --tail 80 "$container" >&2 || true
  done
}

stop_mothership() {
  [[ $MOTHERSHIP_UP == 1 ]] || return 0
  (
    cd "$MOTHERSHIP_DIR"
    docker compose --profile app --profile storage down -v --remove-orphans
  ) >/dev/null 2>&1 || true
  MOTHERSHIP_UP=0
}

cleanup() {
  status=$?
  set +e
  ((status == 0)) || diagnostics
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if [[ $NODE_UP == 1 && -f $NODE_DIR/docker-compose.yaml ]]; then
      (cd "$NODE_DIR" && docker compose --profile voip down -v --remove-orphans) \
        >/dev/null 2>&1 || true
    fi
    [[ $BROKER_UP == 0 ]] || docker rm -f installer-ci-nats >/dev/null 2>&1 || true
    stop_mothership
  fi
  case "$RUN_ROOT" in
    "${RUNNER_TEMP:-/tmp}"/voipappz-installer.*) rm -rf -- "$RUN_ROOT" ;;
  esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

wait_http() {
  url=$1
  timeout=${2:-300}
  deadline=$((SECONDS + timeout))
  until curl -fsS --max-time 5 "$url" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "timed out waiting for $url"
    sleep 3
  done
}

render_example() {
  output=$1
  node_uuid=$2
  sip_uuid=$3
  node_name=$4
  node_type=$5
  internal_ip=$6
  example="$MOTHERSHIP_DIR/config/va.yaml.example"
  scratch="$output.with-customer"

  sed \
    -e 's/^  name: ExampleOrg$/  name: Installer CI/' \
    -e 's/^  domain: pbx\.example\.com.*/  domain: installer-ci.invalid/' \
    -e 's/^  email: admin@example\.com$/  email: installer-ci@example.invalid/' \
    -e "s/00000000-0000-0000-0000-000000000002/$node_uuid/g" \
    -e "s/00000000-0000-0000-0000-000000000003/$sip_uuid/g" \
    -e "s/00000000-0000-0000-0000-000000000004/$GATEWAY_UUID/g" \
    -e "s/^  name: Node1$/  name: $node_name/" \
    -e "s/^  type: app$/  type: $node_type/" \
    -e "s/10\.0\.0\.10/$internal_ip/g" \
    -e "s/203\.0\.113\.10/$internal_ip/g" \
    "$example" > "$scratch"

  # Customer records belong to the API. A node YAML contains node/SIP data.
  sed '/^customers:/,/^nodes:/{ /^nodes:/!d; }' "$scratch" > "$output"
  rm -f -- "$scratch"
  if [[ $node_type == switch ]]; then
    sed -i '/^  - app$/d' "$output"
    cat >> "$output" <<YAML

mothership:
  url: '$API_URL'
broker:
  url: 'nats://127.0.0.1:4222'
YAML
  fi
}

assert_no_secret_in_log() {
  log=$1
  for value in "$VA_REGISTRY_TOKEN" "$BASIC_AUTH" "$BASIC_VALUE" "$ACCOUNT_PASSWORD"; do
    [[ -z $value ]] && continue
    grep -Fq -- "$value" "$log" && die "a credential was written to $(basename "$log")"
  done
  return 0
}

show_safe_log() {
  log=$1
  if grep -Fq -- "$VA_REGISTRY_TOKEN" "$log" || \
     { [[ -n $BASIC_VALUE ]] && grep -Fq -- "$BASIC_VALUE" "$log"; }; then
    echo "installer log withheld because it contains a credential: $log" >&2
  else
    tail -100 "$log" >&2 || true
  fi
}

run_installer() {
  expected=$1
  label=$2
  shift 2
  LAST_LOG="$LOG_DIR/$label.log"
  set +e
  env \
    INSTALL_DIR="$NODE_DIR" \
    VA_CONFIG= \
    VA_REGISTER=1 \
    START=0 \
    VA_CUSTOMER_UUID= \
    VA_CUSTOMER_NAME= \
    VA_API_AUTHORIZATION="$BASIC_AUTH" \
    VA_REGISTRY_USER="$VA_REGISTRY_USER" \
    VA_REGISTRY_TOKEN="$VA_REGISTRY_TOKEN" \
    "$@" \
    sh "$ROOT/install.sh" >"$LAST_LOG" 2>&1
  status=$?
  set -e

  assert_no_secret_in_log "$LAST_LOG"
  if [[ $expected == success && $status -eq 0 ]]; then
    pass "$label"
  elif [[ $expected == failure && $status -ne 0 ]]; then
    pass "$label fails safely"
  else
    show_safe_log "$LAST_LOG"
    die "$label returned $status (expected $expected)"
  fi
}

api() {
  method=$1
  path=$2
  shift 2
  printf 'header = "Authorization: %s"\nheader = "Accept: application/json"\n' "$BASIC_AUTH" |
    curl --config - --fail-with-body --silent --show-error \
      --connect-timeout 10 --max-time 120 --request "$method" \
      "$@" --url "$API_URL/api$path"
}

assert_jq() {
  json=$1
  filter=$2
  label=$3
  printf '%s' "$json" | jq -e "$filter" >/dev/null || die "$label"
  pass "$label"
}

assert_full_mothership() {
  containers=$(awk -F '\t' '
    $1 !~ /^#/ && $3 ~ /(^|,)app(,|$)|(^|,)storage(,|$)/ { print $2 }
  ' "$MOTHERSHIP_DIR/config/services.tsv")
  deadline=$((SECONDS + 180))
  while :; do
    missing=""
    for container in $containers; do
      [[ $(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true) == true ]] \
        || missing="$missing $container"
    done
    [[ -z $missing ]] && break
    ((SECONDS < deadline)) || die "mothership services are not running:$missing"
    sleep 3
  done
  [[ $(docker inspect -f '{{.State.ExitCode}}' va-db-init) == 0 ]] \
    || die 'mothership db-init failed'
  [[ $(docker inspect -f '{{.State.ExitCode}}' va-createbuckets) == 0 ]] \
    || die 'mothership bucket initialization failed'
  pass 'complete mothership app/storage environment is running'
}

printf 'Real VoIPAppz installer integration\n'

command -v docker >/dev/null 2>&1 && die 'Docker must be absent at test start'
INTERNAL_IP=$(ip route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
[[ -n $INTERNAL_IP && $INTERNAL_IP != 127.* ]] || die 'could not detect a usable runner IP'
render_example "$BOOT_CONFIG" "$NODE_UUID" "$NODE_SIP_UUID" Installer-CI-Node switch "$INTERNAL_IP"

# First invocation has no Docker and must install it, pull the private node
# image, extract its stack, verify its in-container CLI, and install the YAML.
FIRST_LOG="$LOG_DIR/clean-install.log"
env \
  INSTALL_DIR="$NODE_DIR" \
  VA_CONFIG="$BOOT_CONFIG" \
  VA_API_URL="$API_URL" \
  VA_NATS_URL=nats://127.0.0.1:4222 \
  VA_REGISTER=0 \
  START=0 \
  VA_REGISTRY_USER="$VA_REGISTRY_USER" \
  VA_REGISTRY_TOKEN="$VA_REGISTRY_TOKEN" \
  sh "$ROOT/install.sh" >"$FIRST_LOG" 2>&1 || {
    show_safe_log "$FIRST_LOG"
    die 'clean installation failed'
  }
assert_no_secret_in_log "$FIRST_LOG"
docker info >/dev/null
docker compose version >/dev/null
docker image inspect nirlevi/va-crystal:node >/dev/null
docker run --rm --entrypoint voipappz nirlevi/va-crystal:node node --help >/dev/null \
  || die 'node image CLI is unavailable'
grep -Fq -- './config/va.yaml:/tmp/node.yaml' "$NODE_DIR/docker-compose.yaml" \
  || die 'compose does not mount va.yaml at /tmp/node.yaml'
[[ -f $NODE_DIR/config/va.yaml ]] || die 'va.yaml was not installed'
find /tmp -maxdepth 1 -type d -name 'voipappz-docker-auth.*' -print -quit | grep -q . \
  && die 'temporary installer Docker credentials were not removed'
pass 'clean host installs Docker, image, stack, and va.yaml'

# A separate temporary Docker config is used only by this test environment to
# pull the full mothership images. The installer already removed its own.
mkdir -m 0700 "$DOCKER_AUTH_DIR"
export DOCKER_CONFIG="$DOCKER_AUTH_DIR"
printf '%s' "$VA_REGISTRY_TOKEN" |
  docker login -u "$VA_REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
  || die 'Docker Hub login failed for mothership images'

# Configure the public mothership checkout from its own committed example and
# boot the complete app + storage environment with Docker Compose. The runtime
# CLI stays inside the node image and is used only for setup and node commands.
mkdir -p "$MOTHERSHIP_DIR/config"
render_example "$MOTHERSHIP_DIR/config/va.yaml" \
  "$APP_UUID" "$APP_SIP_UUID" Installer-CI-App app "$INTERNAL_IP"
docker run --rm --network host \
  --user "$(id -u):$(id -g)" \
  --entrypoint voipappz \
  -e VA_PROJECT_DIR=/work -e VA_PATH= -e "VA_API_URL=$API_URL" \
  -v "$MOTHERSHIP_DIR:/work" -w /work \
  nirlevi/va-crystal:node setup --ci \
  >"$LOG_DIR/mothership-setup.log" 2>&1
MOTHERSHIP_UP=1
(
  cd "$MOTHERSHIP_DIR"
  docker compose --profile app --profile storage up -d
) >"$LOG_DIR/mothership-up.log" 2>&1 || {
  show_safe_log "$LOG_DIR/mothership-up.log"
  die 'complete mothership environment failed to start'
}
wait_http "$API_URL/health" 600
wait_http http://127.0.0.1:9000/minio/health/live 180
wait_http http://127.0.0.1:8222/healthz 180
assert_full_mothership

# A fresh mothership cannot authenticate an HTTP customer POST yet. Its real
# onboarding script runs Mediators::Customer::Init once and creates the first
# Account; restarting web applies the generated VA_ROOT entry.
(
  cd "$MOTHERSHIP_DIR"
  NAME=Installer-CI-Bootstrap \
  EMAIL="$ACCOUNT_EMAIL" \
  PASSWORD="$ACCOUNT_PASSWORD" \
    ./scripts/onboard-customer.sh
) >"$ONBOARD_OUTPUT" 2>&1 || {
  grep -v '^RESULT_PASSWORD=' "$ONBOARD_OUTPUT" >&2 || true
  die 'real mothership onboarding failed'
}
unexpected_warn=$(grep '^INIT_WARN:' "$ONBOARD_OUTPUT" | \
  grep -v "environment domain .* replaced" || true)
[[ -z $unexpected_warn ]] || die "Customer::Init warning: $unexpected_warn"
FIRST_UUID=$(sed -n 's/^RESULT_CUSTOMER=//p' "$ONBOARD_OUTPUT" | head -1)
ACCOUNT_UUID=$(sed -n 's/^RESULT_ACCOUNT_UUID=//p' "$ONBOARD_OUTPUT" | head -1)
[[ $FIRST_UUID =~ ^[0-9a-f-]{36}$ && $ACCOUNT_UUID =~ ^[0-9a-f-]{36}$ ]] \
  || die 'onboarding returned invalid UUIDs'
(
  cd "$MOTHERSHIP_DIR"
  docker compose --profile app up -d --force-recreate web
) >/dev/null
wait_http "$API_URL/health" 300

BASIC_VALUE=$(printf '%s' "$ACCOUNT_EMAIL:$ACCOUNT_PASSWORD" | base64 | tr -d '\n')
BASIC_AUTH="Basic $BASIC_VALUE"
deadline=$((SECONDS + 180))
until api GET /customers >/dev/null 2>&1; do
  ((SECONDS < deadline)) || die 'onboarded Account could not authenticate'
  sleep 3
done
pass 'real Customer::Init created the bootstrap customer and Account'

# Customer::Init correctly homes the bootstrap customer on the app node. Make
# that test fixture unassigned so the installer can exercise its existing-
# customer link path without weakening the rule that forbids implicit moves.
docker exec -e "CI_CUSTOMER_UUID=$FIRST_UUID" va-app sh -c \
  'cd /opt/va-voipbox-api && bundle exec ruby -r ./lib/application -e "Customer.find_by_uuid(ENV.fetch(%q{CI_CUSTOMER_UUID})).update(node_uuid: nil)"' \
  >/dev/null
customer=$(api GET "/customers/$FIRST_UUID")
assert_jq "$customer" '.node_uuid == null' 'bootstrap customer is available for node assignment'

# A caller-provided mothership URL is authoritative even when an existing YAML
# points elsewhere. The CLI must register from the persisted override.
sed -i "s#url: '$API_URL'#url: 'https://cloud.voipappz.io'#" "$NODE_DIR/config/va.yaml"
run_installer success existing-customer \
  VA_API_URL="$API_URL" VA_API_AUTHORIZATION= \
  VA_API_EMAIL="$ACCOUNT_EMAIL" VA_API_PASSWORD="$ACCOUNT_PASSWORD"
grep -Fq "url: '$API_URL'" "$NODE_DIR/config/va.yaml" \
  || die 'explicit mothership URL was not persisted to va.yaml'
pass 'explicit mothership URL overrides the existing YAML'
customer=$(api GET "/customers/$FIRST_UUID")
assert_jq "$customer" ".node_uuid == \"$NODE_UUID\"" \
  'existing customer is linked to this node'
node=$(api GET "/nodes/$NODE_UUID")
assert_jq "$node" ".uuid == \"$NODE_UUID\" and .type == \"switch\"" \
  'existing CLI registered only the YAML node'

run_installer success idempotent-rerun VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'already registered' "$LAST_LOG" \
  || die 'node re-registration was not reported as idempotent'
node_count=$(api GET /nodes | jq --arg uuid "$NODE_UUID" '[.[] | select(.uuid == $uuid)] | length')
[[ $node_count == 1 ]] || die 'node UUID was duplicated on re-registration'
pass 'node registration is idempotent by UUID'

sed -i 's/Installer-CI-Node/Installer-CI-Node-Updated/' "$NODE_DIR/config/va.yaml"
run_installer success node-update VA_CUSTOMER_UUID="$FIRST_UUID"
node=$(api GET "/nodes/$NODE_UUID")
assert_jq "$node" '.name == "Installer-CI-Node-Updated"' \
  'changed YAML node fields are reconciled by the CLI'

run_installer success new-customer VA_CUSTOMER_NAME=Installer-CI-Secondary
customers=$(api GET /customers)
SECOND_UUID=$(printf '%s' "$customers" | jq -r \
  '[.[] | select(.name == "Installer-CI-Secondary")][0].uuid // empty')
[[ $SECOND_UUID =~ ^[0-9a-f-]{36}$ ]] || die 'new customer was not returned by mothership'
assert_jq "$customers" \
  "[.[] | select(.name == \"Installer-CI-Secondary\" and .node_uuid == \"$NODE_UUID\")] | length == 1" \
  'new customer is initialized and linked to the node'
environment_count=$(docker exec va-postgres psql -U postgres -d voipappz -tAc \
  "SELECT COUNT(*) FROM environments WHERE customer_uuid = '$SECOND_UUID'" | tr -d '[:space:]')
[[ $environment_count -ge 1 ]] || die 'Customer::Init created no environment for the new customer'
pass 'new customer used the real Customer::Init environment creation'

before_count=$(printf '%s' "$customers" | jq 'length')
run_installer success existing-customer-by-name VA_CUSTOMER_NAME=Installer-CI-Secondary
after_count=$(api GET /customers | jq 'length')
[[ $after_count == "$before_count" ]] || die 'customer name retry created a duplicate'
pass 'customer name retry is idempotent'

run_installer failure ambiguous-customers
grep -Fq 'set VA_CUSTOMER_UUID or VA_CUSTOMER_NAME' "$LAST_LOG" \
  || die 'ambiguous customer failure was not actionable'
run_installer failure both-customer-selectors \
  VA_CUSTOMER_UUID="$FIRST_UUID" VA_CUSTOMER_NAME=Installer-CI-Secondary
run_installer failure unknown-customer \
  VA_CUSTOMER_UUID=55555555-5555-4555-8555-555555555555

api PATCH "/customers/$FIRST_UUID" --data-urlencode "node_uuid=$OTHER_NODE_UUID" >/dev/null
run_installer failure refuse-customer-rehome VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'refusing to move it' "$LAST_LOG" || die 'customer re-home was not refused'
api PATCH "/customers/$FIRST_UUID" --data-urlencode "node_uuid=$NODE_UUID" >/dev/null
pass 'customer assigned to another node is never moved implicitly'

api PATCH "/customers/$FIRST_UUID" --data-urlencode enabled=false >/dev/null
run_installer failure disabled-customer VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'is disabled' "$LAST_LOG" || die 'disabled customer was not rejected'
api PATCH "/customers/$FIRST_UUID" --data-urlencode enabled=true >/dev/null
pass 'disabled customer is rejected'

printf '%s\n' Installer-CI-Uncertain > "$NODE_DIR/.customer-provisioning-incomplete"
chmod 0600 "$NODE_DIR/.customer-provisioning-incomplete"
run_installer failure incomplete-customer-init VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'has incomplete initialization' "$LAST_LOG" \
  || die 'incomplete Customer::Init marker was ignored'
rm -f -- "$NODE_DIR/.customer-provisioning-incomplete"
pass 'uncertain Customer::Init state cannot be mistaken for success'

customer_count=$(api GET /customers | jq 'length')
run_installer failure invalid-account-auth \
  VA_API_AUTHORIZATION='Basic bm90OnRoZS1hY2NvdW50'
grep -Fq 'no customer change was attempted' "$LAST_LOG" \
  || die 'invalid node authorization did not stop before customer work'
[[ $(api GET /customers | jq 'length') == "$customer_count" ]] \
  || die 'invalid Account auth changed customer state'
grep -Fq 'bm90OnRoZS1hY2NvdW50' "$LAST_LOG" \
  && die 'invalid Account credential was logged'
pass 'bad Account auth stops before customer registration and is redacted'

grep -R -Fq -- "$BASIC_VALUE" "$NODE_DIR/config" "$NODE_DIR/.env" \
  && die 'Account Basic credential was written to node files'
pass 'Account Basic credential is absent from YAML, .env, and installer logs'

# Mothership has now been used only for node/customer registration. Stop it,
# provide an independent test broker, and verify the installed VoIP profile and
# YAML mount without using mothership as a runtime test fixture.
stop_mothership
docker run -d --name installer-ci-nats -p 127.0.0.1:4222:4222 nats:alpine >/dev/null
BROKER_UP=1
sed -i 's#^VA_NATS_URL=.*#VA_NATS_URL=nats://127.0.0.1:4222#' "$NODE_DIR/.env"
sed -i 's#^VA_NATS_HOST=.*#VA_NATS_HOST=127.0.0.1#' "$NODE_DIR/.env"
run_installer success start-voip \
  VA_REGISTER=0 START=1 VA_API_AUTHORIZATION=
NODE_UP=1
wait_http http://127.0.0.1:4000/health 180

# The in-container CLI is the operator interface. Prove the VoIP container is
# running, then use the node-runtime CLI for its aggregate health verdict.
[[ $(docker inspect -f '{{.State.Running}}' va-voip) == true ]] \
  || die 'VoIP service is not running'

deadline=$((SECONDS + 180))
until docker exec va-voip voipappz health \
  >"$LOG_DIR/voip-health.log" 2>&1; do
  if ((SECONDS >= deadline)); then
    show_safe_log "$LOG_DIR/voip-health.log"
    die 'in-container CLI did not report a healthy VoIP node'
  fi
  sleep 3
done

pass 'in-container CLI reports node, Kamailio, dispatcher, and FreeSWITCH health'

mount_source=$(docker inspect va-voip --format \
  '{{range .Mounts}}{{if eq .Destination "/tmp/node.yaml"}}{{.Source}}{{end}}{{end}}')
[[ $(readlink -f "$mount_source") == $(readlink -f "$NODE_DIR/config/va.yaml") ]] \
  || die 'va.yaml is not mounted at /tmp/node.yaml in va-voip'
[[ $(docker exec va-voip printenv VA_NODE_UUID) == "$NODE_UUID" ]] \
  || die 'running node did not load the mounted YAML UUID'
docker exec va-voip sh -c '! env | grep -q "^VA_API_AUTHORIZATION="' \
  || die 'Account authorization reached the running node environment'
pass 'VoIP profile is healthy and loads va.yaml from /tmp/node.yaml'

printf '\nAll real installer checks passed.\n'
