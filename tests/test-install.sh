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
TLS_PROXY_UP=0
TLS_URL=https://localhost:5443

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
    [[ $TLS_PROXY_UP == 0 ]] || docker rm -f installer-ci-tls >/dev/null 2>&1 || true
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
  shift 2 2>/dev/null || shift $#
  deadline=$((SECONDS + timeout))
  until curl -fsS --max-time 5 "$@" "$url" >/dev/null 2>&1; do
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

# A mothership behind TLS that serves its LEAF ONLY — no intermediate. This is
# the real-world deployment mistake the installer met on first contact with a
# live cloud: the chain is valid, but nothing on the client can build it, so the
# image CLI (which verifies HTTPS, and has no insecure switch) refuses to
# connect. VA_CA_BUNDLE is the supported answer, and it must keep verification
# ON — hence a private CA that the runner does not trust by default.
start_tls_proxy() {
  tls_dir="$RUN_ROOT/tls"
  mkdir -p "$tls_dir"
  (
    cd "$tls_dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout root.key -out root.pem \
      -subj '/CN=Installer CI Root' -addext 'basicConstraints=critical,CA:TRUE'
    openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr \
      -subj '/CN=Installer CI Intermediate'
    openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial \
      -days 2 -out int.pem -extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n')
    openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=localhost'
    openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial \
      -days 2 -out leaf.pem -extfile <(printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n')
    # The bundle the operator is given: the anchors the server fails to send.
    cat root.pem int.pem > bundle.pem
    cat > proxy.conf <<'NGINX'
server {
  listen 5443 ssl;
  server_name localhost;
  # Deliberately leaf-only: fullchain.pem here is what fixes it server-side.
  ssl_certificate     /tls/leaf.pem;
  ssl_certificate_key /tls/leaf.key;
  location / {
    proxy_pass http://127.0.0.1:5000;
    proxy_set_header Host $host;
  }
}
NGINX
  ) >/dev/null 2>&1 || die 'could not build the TLS proxy material'
  chmod 0644 "$tls_dir"/*.pem "$tls_dir"/*.key
  docker run -d --name installer-ci-tls --network host \
    -v "$tls_dir:/tls:ro" -v "$tls_dir/proxy.conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine >/dev/null || die 'could not start the TLS proxy'
  TLS_PROXY_UP=1
  wait_http "$TLS_URL/health" 60 --cacert "$tls_dir/bundle.pem"
  # Prove the premise: without the bundle this endpoint is untrusted, with it the
  # chain verifies. A test that passes for the wrong reason would be worthless.
  curl -fsS --max-time 10 "$TLS_URL/health" >/dev/null 2>&1 \
    && die 'test precondition: the leaf-only chain was trusted without the bundle'
  curl -fsS --max-time 10 --cacert "$tls_dir/bundle.pem" "$TLS_URL/health" >/dev/null \
    || die 'test precondition: the CA bundle did not verify the leaf-only chain'
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
# The image CLI re-serializes va.yaml, so match the URL in quoted or bare form.
yaml_mothership_url() {
  sed -n '/^mothership:/,/^[^[:space:]]/{ s/^[[:space:]]*url:[[:space:]]*//p; }' \
    "$NODE_DIR/config/va.yaml" | head -1 | tr -d "'\""
}
sed -i '/^mothership:/,/^[^[:space:]]/ s#^\([[:space:]]*url:\).*#\1 https://cloud.voipappz.io#' \
  "$NODE_DIR/config/va.yaml"
[[ $(yaml_mothership_url) == https://cloud.voipappz.io ]] \
  || die 'test setup could not point the existing YAML at another mothership'
run_installer success existing-customer \
  VA_API_URL="$API_URL" VA_API_AUTHORIZATION= \
  VA_API_EMAIL="$ACCOUNT_EMAIL" VA_API_PASSWORD="$ACCOUNT_PASSWORD"
[[ $(yaml_mothership_url) == "$API_URL" ]] \
  || die 'explicit mothership URL was not persisted to va.yaml'
pass 'explicit mothership URL overrides the existing YAML'
customer=$(api GET "/customers/$FIRST_UUID")
assert_jq "$customer" ".node_uuid == \"$NODE_UUID\"" \
  'existing customer is linked to this node'
node=$(api GET "/nodes/$NODE_UUID")
assert_jq "$node" ".uuid == \"$NODE_UUID\" and .type == \"switch\"" \
  'existing CLI registered only the YAML node'

# An invalid explicit URL must be rejected before it is persisted; otherwise a
# rerun without the override would inherit the bad value from va.yaml.
yaml_before=$(cat "$NODE_DIR/config/va.yaml")
run_installer failure invalid-explicit-url \
  VA_API_URL=http://cloud.voipappz.example VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'must use HTTPS' "$LAST_LOG" || die 'invalid mothership URL was not rejected'
[[ $(cat "$NODE_DIR/config/va.yaml") == "$yaml_before" ]] \
  || die 'invalid mothership URL was written to va.yaml'
grep -Fq 'VA_API_URL=http://cloud.voipappz.example' "$NODE_DIR/.env" \
  && die 'invalid mothership URL was written to .env'
pass 'invalid explicit mothership URL is rejected before it is persisted'

# The same mothership over HTTPS with an incomplete chain. Registration and the
# customer API must both fail without VA_CA_BUNDLE and both succeed with it.
start_tls_proxy
run_installer failure tls-untrusted-chain \
  VA_API_URL="$TLS_URL" VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'no customer change was attempted' "$LAST_LOG" \
  || die 'an unverifiable mothership chain did not stop before customer work'

run_installer success tls-ca-bundle \
  VA_API_URL="$TLS_URL" VA_CUSTOMER_UUID="$FIRST_UUID" \
  VA_CA_BUNDLE="$RUN_ROOT/tls/bundle.pem"
cmp -s "$RUN_ROOT/tls/bundle.pem" "$NODE_DIR/config/ca-bundle.pem" \
  || die 'CA bundle was not installed to config/ca-bundle.pem'
customer=$(api GET "/customers/$FIRST_UUID")
assert_jq "$customer" ".node_uuid == \"$NODE_UUID\"" \
  'customer API over the CA-bundled mothership linked the node'
pass 'an incomplete mothership TLS chain is usable only through VA_CA_BUNDLE'

# The bundle persists across reruns, so the URL keeps working without repeating
# VA_CA_BUNDLE — and the installer never silently drops back to plain HTTP.
run_installer success tls-persisted-bundle \
  VA_API_URL="$TLS_URL" VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq "keeping $NODE_DIR/config/ca-bundle.pem" "$LAST_LOG" \
  || die 'installed CA bundle was not reused on a later run'
pass 'installed CA bundle is reused on later runs'

docker rm -f installer-ci-tls >/dev/null 2>&1
TLS_PROXY_UP=0
rm -f -- "$NODE_DIR/config/ca-bundle.pem"
run_installer success plain-http-after-tls \
  VA_API_URL="$API_URL" VA_CUSTOMER_UUID="$FIRST_UUID"
pass 'a removed CA bundle leaves the plain mothership working'

# A root-owned installation directory keeps .env at mode 0600, so Compose has to
# run elevated even when the Docker socket is reachable unelevated.
ROOT_DIR=/opt/voipappz-ci
# GitHub runners ship /opt world-writable, so the installer would (correctly)
# stay unelevated there. Make the directory genuinely root-owned first.
sudo rm -rf -- "$ROOT_DIR"
sudo install -d -o root -g root -m 0755 "$ROOT_DIR"
run_installer success root-owned-install \
  INSTALL_DIR="$ROOT_DIR" VA_CONFIG="$BOOT_CONFIG" VA_REGISTER=0 START=0
sudo test -O "$ROOT_DIR/.env" || die 'root-owned .env was not created by root'
(cd "$ROOT_DIR" && docker compose --profile voip config >/dev/null 2>&1) \
  && die 'test precondition: unelevated compose could still read the root .env'
sudo rm -rf -- "$ROOT_DIR"
pass 'installation into a root-owned directory runs Compose elevated'

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

# Authenticating is not the same as being allowed to write nodes: node CRUD is
# deployment-wide, so the API restricts it to the cross-tenant accounts listed in
# VA_ROOT and answers 403 to everyone else. A live install met exactly this, and
# a 403 must stop before any customer change instead of reading as a bad login.
LIMITED_EMAIL=installer-ci-limited@example.invalid
LIMITED_PASSWORD='Vpz-Installer-CI-Limited-2026!'
limited=$(api POST /accounts \
  --data-urlencode "email=$LIMITED_EMAIL" \
  --data-urlencode "password=$LIMITED_PASSWORD" \
  --data-urlencode "name=Installer CI Limited" \
  --data-urlencode 'enabled=true')
assert_jq "$limited" '.uuid | type == "string"' 'a non-root Account exists for the 403 test'
LIMITED_BASIC=$(printf '%s' "$LIMITED_EMAIL:$LIMITED_PASSWORD" | base64 | tr -d '\n')
deadline=$((SECONDS + 120))
until printf 'header = "Authorization: Basic %s"\n' "$LIMITED_BASIC" |
  curl --config - --silent --fail --max-time 10 --url "$API_URL/api/customers" >/dev/null 2>&1; do
  ((SECONDS < deadline)) || die 'the non-root Account could not authenticate'
  sleep 3
done
limited_status=$(printf 'header = "Authorization: Basic %s"\n' "$LIMITED_BASIC" |
  curl --config - --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 20 --request POST --url "$API_URL/api/nodes")
[[ $limited_status == 403 ]] \
  || die "test precondition: the non-root Account got HTTP $limited_status, not 403, from POST /nodes"

customer_count=$(api GET /customers | jq 'length')
run_installer failure unauthorized-account \
  VA_API_AUTHORIZATION="Basic $LIMITED_BASIC"
grep -Fq 'no customer change was attempted' "$LAST_LOG" \
  || die 'a forbidden Account did not stop before customer work'
[[ $(api GET /customers | jq 'length') == "$customer_count" ]] \
  || die 'a forbidden Account changed customer state'
grep -Fq "$LIMITED_BASIC" "$LAST_LOG" && die 'the non-root credential was logged'
pass 'an authenticated Account without node rights fails before customer work'

# Mothership has now been used only for node/customer registration. Stop it,
# provide an independent test broker, and verify the installed VoIP profile and
# YAML mount without using mothership as a runtime test fixture.
stop_mothership
# Bind the broker to the runner's own address, not loopback: a real node reaches
# NATS over the network, and the voip service maps `nats` to VA_NATS_HOST, so a
# loopback-only test would never exercise that path.
docker run -d --name installer-ci-nats -p "$INTERNAL_IP:4222:4222" nats:alpine >/dev/null
BROKER_UP=1
BROKER_URL="nats://$INTERNAL_IP:4222"
deadline=$((SECONDS + 60))
until (exec 3<>"/dev/tcp/$INTERNAL_IP/4222") 2>/dev/null; do
  ((SECONDS < deadline)) || die 'the remote test broker never accepted connections'
  sleep 2
done
sed -i "s#^\([[:space:]]*\)url: .nats://[^\"']*.#\1url: '$BROKER_URL'#" "$NODE_DIR/config/va.yaml"
grep -Fq "$BROKER_URL" "$NODE_DIR/config/va.yaml" \
  || die 'test setup could not point va.yaml at the remote broker'
# The stack pins container names, so a leftover va-voip from an earlier
# installation directory blocks Compose. An abandoned one is reclaimed; the
# installer must not need a manual `docker rm` between runs.
STALE_DIR="$RUN_ROOT/stale-node"
mkdir -p "$STALE_DIR"
(cd "$STALE_DIR" && cp "$NODE_DIR/docker-compose.yaml" . && cp -r "$NODE_DIR/config" . \
  && cp "$NODE_DIR/.env" . && docker compose --profile voip create va-voip) >/dev/null 2>&1 \
  || die 'could not stage a conflicting va-voip container'
[[ $(docker inspect va-voip --format \
  '{{index .Config.Labels "com.docker.compose.project.working_dir"}}') == "$STALE_DIR" ]] \
  || die 'test setup did not create a foreign va-voip container'

# Docker refuses a name in extra_hosts, so a broker named by DNS has to reach
# Compose as an address. START=0: this asserts the environment, not a runtime.
BROKER_NAME_URL="nats://localhost:4222"
cp "$NODE_DIR/config/va.yaml" "$RUN_ROOT/va.yaml.ip-broker"
sed -i "s#^\([[:space:]]*\)url: .nats://[^\"']*.#\1url: '$BROKER_NAME_URL'#" \
  "$NODE_DIR/config/va.yaml"
run_installer success named-broker VA_REGISTER=0 START=0 VA_API_AUTHORIZATION=
grep -Fq "VA_NATS_URL=$BROKER_NAME_URL" "$NODE_DIR/.env" \
  || die 'a named broker URL was not written to the Compose environment'
grep -qE '^VA_NATS_HOST=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$NODE_DIR/.env" \
  || die 'a named broker was not resolved to an address for extra_hosts'
cp "$RUN_ROOT/va.yaml.ip-broker" "$NODE_DIR/config/va.yaml"
pass 'a broker named by DNS reaches Compose as an address'

run_installer success start-voip \
  VA_REGISTER=0 START=1 VA_API_AUTHORIZATION=
NODE_UP=1
grep -Fq 'removing the abandoned container va-voip' "$LAST_LOG" \
  || die 'a conflicting container from another directory was not reclaimed'
[[ $(docker inspect va-voip --format \
  '{{index .Config.Labels "com.docker.compose.project.working_dir"}}') == "$NODE_DIR" ]] \
  || die 'the running va-voip does not belong to this installation'
rm -rf -- "$STALE_DIR"
pass 'a container left by another installation directory is reclaimed'
# The CLI reads the YAML; the installer must carry that value into Compose, or
# the voip service maps `nats` to the wrong host.
grep -Fq "VA_NATS_URL=$BROKER_URL" "$NODE_DIR/.env" \
  || die 'the remote broker URL was not written to the Compose environment'
grep -Fq "VA_NATS_HOST=$INTERNAL_IP" "$NODE_DIR/.env" \
  || die 'the remote broker host was not written to the Compose environment'
[[ $(docker inspect va-voip --format \
  '{{range .HostConfig.ExtraHosts}}{{.}} {{end}}') == *"nats:$INTERNAL_IP"* ]] \
  || die 'the voip service does not resolve nats to the remote broker'
pass 'a non-loopback broker URL reaches Compose and the running node'
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
