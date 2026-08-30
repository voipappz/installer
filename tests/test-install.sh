#!/usr/bin/env bash
# Real installer integration test. It boots the complete public mothership
# app/storage environment and talks to its actual Ruby API and Customer::Init.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The mothership fixture is NOT cloned: it is DOWNLOADED, the same way the
# mothership's own installer gets it — the public tarball of voipappz/mothership.
# (The node image used to carry the stack at /stack; va-crystal dropped that on
# 2026-08-26, so the image is the node and nothing else.) A local checkout may
# still be passed as $1 by a developer testing uncommitted mothership changes.
MOTHERSHIP_DIR=${1:-}
if [[ -n $MOTHERSHIP_DIR ]]; then
  [[ -f $MOTHERSHIP_DIR/docker-compose.yaml ]] || {
    echo "usage: tests/test-install.sh [/path/to/mothership]" >&2
    exit 2
  }
  MOTHERSHIP_DIR=$(cd "$MOTHERSHIP_DIR" && pwd)
fi

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
TLS_SELF_URL=https://localhost:5444

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
  # The node's own view, when it is up: which check is red and why, what
  # FreeSWITCH bound, and what it complained about — the three things a
  # "did not pass node health" needs beside it to be diagnosable from a log.
  if docker inspect va-voip >/dev/null 2>&1; then
    echo '--- va-voip: voipappz health' >&2
    docker exec va-voip voipappz health >&2 2>&1 || true
    echo '--- va-voip: sofia status' >&2
    docker exec va-voip sh -c 'fs_cli -H 127.0.0.1 -P 8021 -p "$VA_FREESWITCH_PASSWORD" -x "sofia status"' >&2 2>&1 || true
    echo '--- va-voip: listeners' >&2
    docker exec va-voip sh -c 'ss -lun; ss -lnt' >&2 2>&1 || true
    echo '--- va-voip: FreeSWITCH errors' >&2
    docker logs va-voip 2>&1 | grep -E '\[(ERR|CRIT)\]' | grep -viE 'sqldb|vpx|codec' | tail -20 >&2 || true
  fi
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
    [[ $NODE_UP == 0 ]] || docker rm -f va-voip >/dev/null 2>&1 || true
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
  # THIS repository's example, not the mothership's: a node YAML, with the
  # sofia ports the node stack actually uses. The mothership's example says
  # port_internal 5080, and the node's health checks probe 5070 (the constant
  # in cli/src/helpers/node_env.cr; nothing exports VA_SOFIA_INTERNAL_PORT),
  # so a node built from that file fails health on a port it never bound.
  example="$ROOT/va.yaml.example"
  scratch="$output.with-customer"

  sed \
    -e 's/^  name: ExampleOrg$/  name: Installer CI/' \
    -e 's/^  domain: pbx\.example\.com.*/  domain: installer-ci.invalid/' \
    -e 's/^  email: admin@example\.com$/  email: installer-ci@example.invalid/' \
    -e "s/00000000-0000-0000-0000-000000000002/$node_uuid/g" \
    -e "s/00000000-0000-0000-0000-000000000003/$sip_uuid/g" \
    -e "s/00000000-0000-0000-0000-000000000004/$GATEWAY_UUID/g" \
    -e "s/^  name: Node1$/  name: $node_name/" \
    -e "s/^  type: .*$/  type: $node_type/" \
    -e "s/10\.0\.0\.10/$internal_ip/g" \
    -e "s/203\.0\.113\.10/$internal_ip/g" \
    "$example" > "$scratch"

  # Customer records belong to the API. A node YAML contains node/SIP data.
  sed '/^customers:/,/^nodes:/{ /^nodes:/!d; }' "$scratch" > "$output"
  rm -f -- "$scratch"
  if [[ $node_type == switch ]]; then
    sed -i '/^  - app$/d' "$output"
    # The example already carries both sections: replace the values in place,
    # or a second `mothership:` key would shadow the first.
    sed -i "/^mothership:/,/^[^[:space:]#]/ s#^\([[:space:]]*url:\).*#\1 '$API_URL'#" "$output"
    sed -i "/^broker:/,/^[^[:space:]#]/ s#^\([[:space:]]*url:\).*#\1 'nats://127.0.0.1:4222'#" "$output"
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
  if printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then
    pass "$label"
    return
  fi
  # THE PAYLOAD, ALWAYS. A bare "not ok - <label>" costs a whole CI cycle to
  # turn into a fact; these are node and customer records, which carry no
  # credential (assert_no_secret_in_log guards the installer logs separately).
  printf '\n--- the filter that failed:  %s\n--- on this payload:\n%s\n' \
    "$filter" "${json:-<empty body>}" >&2
  die "$label"
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
    # And the common field case: a self-signed mothership, pinnable as is.
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout self.key -out self.pem \
      -subj '/CN=voipappz.local' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
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
server {
  listen 5444 ssl;
  server_name localhost;
  ssl_certificate     /tls/self.pem;
  ssl_certificate_key /tls/self.key;
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

# First invocation has no Docker and must install it, pull the private node
# image, extract its stack, verify its in-container CLI, and — with no YAML
# and no terminal — create va.yaml from the node CLI's defaults.
FIRST_LOG="$LOG_DIR/clean-install.log"
env \
  INSTALL_DIR="$NODE_DIR" \
  VA_CONFIG= \
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
docker image inspect nirlevi/va-crystal:node >/dev/null
docker run --rm --entrypoint voipappz nirlevi/va-crystal:node node --help >/dev/null \
  || die 'node image CLI is unavailable'
# The image is the whole node: no compose scaffold to extract, and none left
# behind. An installation directory holds this node's files and nothing else.
[[ -e $NODE_DIR/docker-compose.yaml ]] \
  && die 'the installation directory carries a compose file; the image ships no stack'
[[ -f $NODE_DIR/config/va.yaml ]] || die 'va.yaml was not created by the node CLI defaults'
grep -Eq 'uuid: [0-9a-f]{8}-[0-9a-f-]{27}' "$NODE_DIR/config/va.yaml" || die 'the unattended va.yaml has no node uuid'
find /tmp -maxdepth 1 -type d -name 'voipappz-docker-auth.*' -print -quit | grep -q . \
  && die 'temporary installer Docker credentials were not removed'
pass 'clean host installs Docker, the image and va.yaml'

# The mothership fixture: downloaded, not cloned — the same public tarball its
# own installer fetches. The node image carries no stack any more.
if [[ -z $MOTHERSHIP_DIR ]]; then
  MOTHERSHIP_DIR="$RUN_ROOT/mothership"
  mkdir -p "$MOTHERSHIP_DIR"
  curl -fL --retry 5 --retry-all-errors -o "$RUN_ROOT/mothership.tar.gz" \
    "https://github.com/voipappz/mothership/archive/refs/heads/${VA_MOTHERSHIP_REF:-main}.tar.gz" \
    || die 'could not download the mothership stack'
  tar -xzf "$RUN_ROOT/mothership.tar.gz" -C "$RUN_ROOT"
  top=$(find "$RUN_ROOT" -maxdepth 1 -type d -name 'mothership-*' | head -1)
  [[ -n $top ]] || die 'the mothership tarball did not unpack'
  (cd "$top" && tar -cf - .) | (cd "$MOTHERSHIP_DIR" && tar -xf -)
  for f in docker-compose.yaml config/va.yaml.example scripts/onboard-customer.sh; do
    [[ -f $MOTHERSHIP_DIR/$f ]] || die "the mothership tarball lacks $f"
  done
  pass 'mothership fixture downloaded (nothing cloned)'
fi
render_example "$BOOT_CONFIG" "$NODE_UUID" "$NODE_SIP_UUID" Installer-CI-Node switch "$INTERNAL_IP"

# The rest of the test talks about THIS node: a supplied YAML replaces the
# unattended default one, and the CLI must read the supplied UUID back.
run_installer success supplied-yaml-replaces-default \
  VA_CONFIG="$BOOT_CONFIG" VA_API_URL="$API_URL" VA_NATS_URL=nats://127.0.0.1:4222 VA_REGISTER=0
grep -Fq "$NODE_UUID" "$NODE_DIR/config/va.yaml" || die 'the supplied va.yaml did not replace the default one'
pass 'a supplied va.yaml replaces the unattended default'

# Offline image source: a docker-save archive loaded with VA_IMAGE_ARCHIVE and
# no registry credentials. The archive is saved under another tag so the load
# and retag path is exercised without a second registry pull.
ARCHIVE_DIR="$(mktemp -d)"
chmod 0755 "$ARCHIVE_DIR"   # nginx (below) serves it as an unprivileged worker
ARCHIVE_LOG="$LOG_DIR/archive-install.log"
docker tag nirlevi/va-crystal:node installer-ci/va-crystal:archive
docker save installer-ci/va-crystal:archive | gzip -1 >"$ARCHIVE_DIR/va-crystal.tar.gz"
docker rmi installer-ci/va-crystal:archive >/dev/null
env -u VA_REGISTRY_USER -u VA_REGISTRY_TOKEN \
  INSTALL_DIR="$ARCHIVE_DIR/node" \
  VA_VOIP_IMAGE=installer-ci/va-crystal:loaded \
  VA_IMAGE_ARCHIVE="$ARCHIVE_DIR/va-crystal.tar.gz" \
  VA_CONFIG="$BOOT_CONFIG" \
  VA_API_URL="$API_URL" \
  VA_NATS_URL=nats://127.0.0.1:4222 \
  VA_REGISTER=0 \
  START=0 \
  sh "$ROOT/install.sh" </dev/null >"$ARCHIVE_LOG" 2>&1 || {
    show_safe_log "$ARCHIVE_LOG"
    die 'installation from an image archive failed'
  }
docker image inspect installer-ci/va-crystal:loaded >/dev/null \
  || die 'the loaded archive was not tagged as VA_VOIP_IMAGE'
grep -Fq -- 'tagged installer-ci/va-crystal:archive as installer-ci/va-crystal:loaded' "$ARCHIVE_LOG" \
  || die 'archive install did not report the retag'
! grep -Fq -- 'logging in to' "$ARCHIVE_LOG" || die 'archive install contacted the registry'
[[ -f $ARCHIVE_DIR/node/config/va.yaml ]] || die 'archive install did not install va.yaml'
docker rmi installer-ci/va-crystal:loaded >/dev/null
pass 'installs from a local image archive without registry credentials'

# URL source: the same archive served over HTTP with its .sha256 beside it,
# as S3 publishes it. VA_IMAGE_SOURCE=archive + a URL, no registry variables.
URL_LOG="$LOG_DIR/archive-url-install.log"
sha256sum "$ARCHIVE_DIR/va-crystal.tar.gz" | awk '{print $1}' >"$ARCHIVE_DIR/va-crystal.tar.gz.sha256"
chmod 0644 "$ARCHIVE_DIR"/va-crystal.tar.gz "$ARCHIVE_DIR"/va-crystal.tar.gz.sha256
docker run -d --name installer-ci-www -p 127.0.0.1:18080:80 \
  -v "$ARCHIVE_DIR:/usr/share/nginx/html:ro" nginx:alpine >/dev/null
for _ in $(seq 1 30); do curl -fsI http://127.0.0.1:18080/va-crystal.tar.gz.sha256 >/dev/null 2>&1 && break; sleep 1; done
env -u VA_REGISTRY_USER -u VA_REGISTRY_TOKEN \
  INSTALL_DIR="$ARCHIVE_DIR/node-url" \
  VA_VOIP_IMAGE=installer-ci/va-crystal:fromurl \
  VA_IMAGE_SOURCE=archive \
  VA_IMAGE_ARCHIVE=http://127.0.0.1:18080/va-crystal.tar.gz \
  VA_CONFIG="$BOOT_CONFIG" \
  VA_API_URL="$API_URL" \
  VA_NATS_URL=nats://127.0.0.1:4222 \
  VA_REGISTER=0 \
  START=0 \
  sh "$ROOT/install.sh" </dev/null >"$URL_LOG" 2>&1 || {
    show_safe_log "$URL_LOG"
    die 'installation from an image archive URL failed'
  }
docker rm -f installer-ci-www >/dev/null
grep -Fq -- 'sha256 verified' "$URL_LOG" || die 'URL install did not verify the published sha256'
docker image inspect installer-ci/va-crystal:fromurl >/dev/null \
  || die 'the downloaded archive was not tagged as VA_VOIP_IMAGE'
find /tmp -maxdepth 1 -name 'voipappz-image-archive.*' -print -quit | grep -q . \
  && die 'the downloaded archive was not removed'
docker rmi installer-ci/va-crystal:fromurl >/dev/null
pass 'installs from an image archive URL with sha256 verification'

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
# A 404 here is the interesting case, and `set -e` would kill the run with no
# explanation at all — so catch it and print what the mothership DOES hold.
if ! node=$(api GET "/nodes/$NODE_UUID" 2>&1); then
  printf '\n--- GET /nodes/%s failed with:\n%s\n--- the whole node index:\n%s\n--- the installer run that should have registered it:\n' \
    "$NODE_UUID" "$node" "$(api GET /nodes 2>&1 || true)" >&2
  show_safe_log "$LAST_LOG"
  die 'existing CLI registered only the YAML node'
fi
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
# Trust as presented = PIN. A self-signed mothership (the field case: an
# IP-addressed box with its own certificate) pins in one step, no flag, no
# prompt, and registers.
run_installer success tls-self-signed \
  VA_API_URL="$TLS_SELF_URL" VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'pinning it as presented' "$LAST_LOG" \
  || die 'a self-signed mothership was not pinned automatically'
grep -Fq 'CN = voipappz.local' "$LAST_LOG" || grep -Fq 'CN=voipappz.local' "$LAST_LOG" \
  || die 'the pinned certificate was not shown'
customer=$(api GET "/customers/$FIRST_UUID")
assert_jq "$customer" ".node_uuid == \"$NODE_UUID\"" 'the self-signed mothership registered and linked the node'
pass 'a self-signed mothership is pinned automatically and registers'
rm -f -- "$NODE_DIR/config/ca-bundle.pem"

# A public certificate served WITHOUT its intermediate cannot be pinned from
# what it sends: nothing self-signed to anchor on. The installer still saves
# it, the CLI refuses with its pin message, nothing is registered, and
# VA_CA_BUNDLE (next) is the documented answer.
run_installer failure tls-untrusted-chain \
  VA_API_URL="$TLS_URL" VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'pinning it as presented' "$LAST_LOG" \
  || die 'an incomplete mothership chain was not pinned as presented'
grep -Eq 'pinned chain|could not be verified' "$LAST_LOG" \
  || die 'the CLI did not explain the pin failure'
grep -Fq 'no customer change was attempted' "$LAST_LOG" \
  || die 'an incomplete chain did not stop before customer work'
rm -f -- "$NODE_DIR/config/ca-bundle.pem"

run_installer success tls-ca-bundle \
  VA_API_URL="$TLS_URL" VA_CUSTOMER_UUID="$FIRST_UUID" \
  VA_CA_BUNDLE="$RUN_ROOT/tls/bundle.pem"
cmp -s "$RUN_ROOT/tls/bundle.pem" "$NODE_DIR/config/ca-bundle.pem" \
  || die 'CA bundle was not installed to config/ca-bundle.pem'
# The running node calls the mothership for dialplan and SBC routing, so the
# anchors must reach the container, not just registration. START=0 here, so the
# proof is that the installer would mount it: the pin is on disk and named.
grep -Fq "the node will trust $NODE_DIR/config/ca-bundle.pem" "$LAST_LOG" \
  || die 'the CA bundle was not given to the running node'
customer=$(api GET "/customers/$FIRST_UUID")
assert_jq "$customer" ".node_uuid == \"$NODE_UUID\"" \
  'customer API over the CA-bundled mothership linked the node'
pass 'an incomplete mothership TLS chain is usable through VA_CA_BUNDLE'

# The bundle persists across reruns, so the URL keeps working without repeating
# VA_CA_BUNDLE — and the installer never silently drops back to plain HTTP.
run_installer success tls-persisted-bundle \
  VA_API_URL="$TLS_URL" VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq "keeping $NODE_DIR/config/ca-bundle.pem" "$LAST_LOG" \
  || die 'installed CA bundle was not reused on a later run'
pass 'installed CA bundle is reused on later runs'

# THE REAL TERMINAL. Everything above preset its answers in the environment;
# this run types them at the prompts through a pseudo-terminal (expect):
# image source 3 + the archive path, the node wizard (name, internal and
# external IP), the mothership URL of the self-signed proxy — pinned
# automatically, no question — the Account token with echo off, and the new
# customer's login (email, then its password with echo off). Only the
# customer selector and START=0 are preset: neither has a prompt in this case.
command -v expect >/dev/null 2>&1 || sudo apt-get install -y -qq expect >/dev/null
TTY_DIR="$RUN_ROOT/tty-node"
TTY_LOG="$LOG_DIR/tty-install.log"
TTY_PASSWORD="Tty-Login-$RANDOM-$RANDOM"
set +e
env -u VA_REGISTRY_USER -u VA_REGISTRY_TOKEN -u VA_API_AUTHORIZATION -u VA_API_URL -u VA_NATS_URL -u VA_CONFIG \
  INSTALL_DIR="$TTY_DIR" VA_VOIP_IMAGE=installer-ci/va-crystal:tty START=0 VA_REGISTER=1 \
  VA_CUSTOMER_NAME="TTY-Customer" \
  ARCHIVE="$ARCHIVE_DIR/va-crystal.tar.gz" MOTHERSHIP="$TLS_SELF_URL" TOKEN="$BASIC_VALUE" \
  TTY_PASSWORD="$TTY_PASSWORD" \
  expect "$ROOT/tests/tty-install.exp" "$ROOT/install.sh" >"$TTY_LOG" 2>&1
tty_rc=$?
set -e
assert_no_secret_in_log "$TTY_LOG"
if [[ $tty_rc -ne 0 ]]; then show_safe_log "$TTY_LOG"; die "the real-terminal install returned $tty_rc"; fi
grep -Fq 'tty-node' "$TTY_DIR/config/va.yaml" || die 'the name typed at the wizard did not reach va.yaml'
grep -Fq 'pinning it as presented' "$TTY_LOG" || die 'the typed mothership URL was not pinned automatically'
tty_uuid=$(sed -n 's/^- uuid: //p;s/^  uuid: //p' "$TTY_DIR/config/va.yaml" | head -1)
tty_customer=$(api GET "/customers" | jq -r '.[] | select(.name == "TTY-Customer") | .node_uuid')
[[ $tty_customer == "$tty_uuid" ]] || die "the customer created from the terminal run is linked to '$tty_customer', not $tty_uuid"
grep -Fq "$TTY_PASSWORD" "$TTY_LOG" && die 'the login password typed with echo off reached the terminal log'
grep -Fq 'Account tty-owner@installer-ci.test signs in to customer' "$TTY_LOG" \
  || die 'the login typed at the terminal was not proven'
docker rmi installer-ci/va-crystal:tty >/dev/null 2>&1 || true
pass 'a real-terminal install: typed archive, wizard, mothership URL and token register the node'
rm -rf "$ARCHIVE_DIR"

docker rm -f installer-ci-tls >/dev/null 2>&1
TLS_PROXY_UP=0
rm -f -- "$NODE_DIR/config/ca-bundle.pem"
run_installer success plain-http-after-tls \
  VA_API_URL="$API_URL" VA_CUSTOMER_UUID="$FIRST_UUID"
grep -Fq 'will trust' "$LAST_LOG" \
  && die 'a removed CA bundle was still mounted into the node'
pass 'a removed CA bundle leaves the plain mothership working'

# A root-owned installation directory keeps .env at mode 0600, so the installer
# has to read it back elevated even when the Docker socket is reachable
# unelevated — that file holds the three secrets `docker run` needs.
ROOT_DIR=/opt/voipappz-ci
# GitHub runners ship /opt world-writable, so the installer would (correctly)
# stay unelevated there. Make the directory genuinely root-owned first.
sudo rm -rf -- "$ROOT_DIR"
sudo install -d -o root -g root -m 0755 "$ROOT_DIR"
run_installer success root-owned-install \
  INSTALL_DIR="$ROOT_DIR" VA_CONFIG="$BOOT_CONFIG" VA_REGISTER=0 START=0
sudo test -O "$ROOT_DIR/.env" || die 'root-owned .env was not created by root'
[[ -r $ROOT_DIR/.env ]] \
  && die 'test precondition: the root-owned .env was readable unelevated'
sudo rm -rf -- "$ROOT_DIR"
pass 'installation into a root-owned directory reads its secrets elevated'

# An operator OUTSIDE the docker group: every docker call goes through sudo,
# which resets the environment. The registration container must still receive
# the Account authorization (it is handed over on stdin, never as an argument)
# — the first real install failed here with "VA_API_AUTHORIZATION must contain
# a Basic authorization value" while the same run passed from a docker-group
# user. Registration is idempotent by node UUID, so re-registering is safe.
SUDO_USER_NAME=va-ci-nodocker
SUDO_DIR=/tmp/va-ci-nodocker   # /tmp: the RUN_ROOT mktemp dir is 0700 and blocks another user
sudo rm -rf -- "$SUDO_DIR"
sudo userdel -r "$SUDO_USER_NAME" >/dev/null 2>&1 || true
sudo useradd -m -s /bin/sh "$SUDO_USER_NAME"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SUDO_USER_NAME" | sudo tee /etc/sudoers.d/va-ci-nodocker >/dev/null
sudo chmod 0440 /etc/sudoers.d/va-ci-nodocker
sudo -u "$SUDO_USER_NAME" docker info >/dev/null 2>&1 && die 'test precondition: the no-docker user can reach Docker directly'
sudo install -d -o "$SUDO_USER_NAME" -g "$SUDO_USER_NAME" -m 0755 "$SUDO_DIR"
sudo install -o "$SUDO_USER_NAME" -m 0644 "$NODE_DIR/config/va.yaml" "$SUDO_DIR/boot.yaml"
# The runner checkout is not readable by another user; hand over a copy.
sudo install -o "$SUDO_USER_NAME" -m 0644 "$ROOT/install.sh" "$SUDO_DIR/install.sh"
NODOCKER_LOG="$LOG_DIR/nodocker-install.log"
# shellcheck disable=SC2024  # the redirect is meant to be ours, not the sudo user's
sudo -u "$SUDO_USER_NAME" -H env -i PATH="$PATH" HOME="/home/$SUDO_USER_NAME" \
  INSTALL_DIR="$SUDO_DIR/node" VA_CONFIG="$SUDO_DIR/boot.yaml" \
  VA_API_URL="$API_URL" VA_NATS_URL=nats://127.0.0.1:4222 \
  VA_API_AUTHORIZATION="$BASIC_AUTH" VA_CUSTOMER_UUID="$FIRST_UUID" \
  VA_REGISTER=1 START=0 \
  sh "$SUDO_DIR/install.sh" </dev/null >"$NODOCKER_LOG" 2>&1 || {
    show_safe_log "$NODOCKER_LOG"
    die 'installation by a user outside the docker group failed'
  }
assert_no_secret_in_log "$NODOCKER_LOG"
grep -Fq -- 'registering node' "$NODOCKER_LOG" || die 'no-docker-group install never registered'
sudo rm -rf -- "$SUDO_DIR"
sudo rm -f /etc/sudoers.d/va-ci-nodocker
sudo userdel -r "$SUDO_USER_NAME" >/dev/null 2>&1 || true
pass 'a user outside the docker group registers through sudo'

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

SECOND_EMAIL="owner-$RANDOM@installer-ci.test"
SECOND_PASSWORD="Ci-Login-$RANDOM-$RANDOM"
run_installer success new-customer VA_CUSTOMER_NAME=Installer-CI-Secondary \
  VA_ACCOUNT_EMAIL="$SECOND_EMAIL" VA_ACCOUNT_PASSWORD="$SECOND_PASSWORD"
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

second_basic="Basic $(printf '%s:%s' "$SECOND_EMAIL" "$SECOND_PASSWORD" | base64 | tr -d '\n')"
api_as_second() {
  printf 'header = "Authorization: %s"\nheader = "Accept: application/json"\n' "$second_basic" |
    curl --config - --fail-with-body --silent --show-error --connect-timeout 10 --max-time 60 \
      "$@"
}
second_account_uuid=$(api_as_second --get --data-urlencode "search[email]=$SECOND_EMAIL" \
  --url "$API_URL/api/accounts" | jq -r "[.[] | select(.email == \"$SECOND_EMAIL\")] | .[0].uuid // empty")
[[ $second_account_uuid =~ ^[0-9a-f-]{36}$ ]] || die 'the new customer Account cannot sign in with the supplied login'
assert_jq "$(api_as_second --url "$API_URL/api/accounts/$second_account_uuid")" \
  ".customer_uuid == \"$SECOND_UUID\"" \
  'the new customer Account signs in with the supplied email and password'
grep -Fq "$SECOND_PASSWORD" "$LAST_LOG" && die 'the new Account password leaked into the installer log'

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
BOOTSTRAP_ACL=$(api GET /accounts | jq -r --arg email "$ACCOUNT_EMAIL" \
  '.[] | select(.email == $email) | .acl.uuid')
[[ $BOOTSTRAP_ACL =~ ^[0-9a-f-]{36}$ ]] || die 'could not read the bootstrap Account ACL'
limited=$(api POST /accounts \
  --data-urlencode "email=$LIMITED_EMAIL" \
  --data-urlencode "password=$LIMITED_PASSWORD" \
  --data-urlencode "name=Installer CI Limited" \
  --data-urlencode "acl_uuid=$BOOTSTRAP_ACL" \
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

# Registration is idempotent: an unchanged node needs no write, so a non-root
# Account gets that far legitimately. Change a node field first, so the CLI must
# actually write and the 403 is reached.
customer_count=$(api GET /customers | jq 'length')
node_name_before=$(api GET "/nodes/$NODE_UUID" | jq -r '.name')
sed -i "s/^\([[:space:]]*name:\)[[:space:]]*$node_name_before\$/\1 Installer-CI-Node-Forbidden/" \
  "$NODE_DIR/config/va.yaml"
grep -Fq 'Installer-CI-Node-Forbidden' "$NODE_DIR/config/va.yaml" \
  || die 'test setup could not change the node name'
run_installer failure unauthorized-account \
  VA_API_AUTHORIZATION="Basic $LIMITED_BASIC"
[[ $(api GET "/nodes/$NODE_UUID" | jq -r '.name') == "$node_name_before" ]] \
  || die 'a forbidden Account changed the node'
sed -i "s/^\([[:space:]]*name:\)[[:space:]]*Installer-CI-Node-Forbidden\$/\1 $node_name_before/" \
  "$NODE_DIR/config/va.yaml"
grep -Fq 'no customer change was attempted' "$LAST_LOG" \
  || die 'a forbidden Account did not stop before customer work'
[[ $(api GET /customers | jq 'length') == "$customer_count" ]] \
  || die 'a forbidden Account changed customer state'
grep -Fq "$LIMITED_BASIC" "$LAST_LOG" && die 'the non-root credential was logged'
pass 'an authenticated Account without node rights fails before customer work'

# Mothership has now been used only for node/customer registration. Stop it,
# provide an independent test broker, and verify the installed VoIP profile and
# YAML mount without using mothership as a runtime test fixture.
# The mothership STAYS UP: the node's health verdict includes reaching it
# (control_mothership), as a real node must. Its NATS binds loopback; the
# node's broker below binds the runner's address, so the two coexist.
# Bind the broker to the runner's own address, not loopback: a real node reaches
# NATS over the network, and the node reads the broker from va.yaml, so a
# loopback-only test would never exercise that path.
docker run -d --name installer-ci-nats -p "$INTERNAL_IP:4222:4222" nats:alpine >/dev/null
BROKER_UP=1
BROKER_URL="nats://$INTERNAL_IP:4222"
deadline=$((SECONDS + 60))
until (exec 3<>"/dev/tcp/$INTERNAL_IP/4222") 2>/dev/null; do
  ((SECONDS < deadline)) || die 'the remote test broker never accepted connections'
  sleep 2
done
# The CLI re-serializes va.yaml unquoted, so replace the url line under the
# broker key rather than matching a quoted value.
sed -i "/^broker:/,/^[^[:space:]#]/ s#^\([[:space:]]*url:\).*#\1 '$BROKER_URL'#" \
  "$NODE_DIR/config/va.yaml"
grep -Fq "$BROKER_URL" "$NODE_DIR/config/va.yaml" \
  || die 'test setup could not point va.yaml at the remote broker'
# A leftover va-voip from an earlier run holds the name this installer uses.
# Replacing it is how a node is upgraded, so the installer must not need a
# manual `docker rm` between runs. Stage one that is plainly not ours.
STALE_DIR="$RUN_ROOT/stale-node"
mkdir -p "$STALE_DIR"
docker rm -f va-voip >/dev/null 2>&1 || true
docker create --name va-voip alpine:3.20 sleep 3600 >/dev/null \
  || die 'could not stage a conflicting va-voip container'
[[ $(docker inspect va-voip --format '{{.Config.Image}}') == alpine:3.20 ]] \
  || die 'test setup did not create a foreign va-voip container'

# Docker refuses a name in extra_hosts, so a broker named by DNS has to reach
# Compose as an address. START=0: this asserts the environment, not a runtime.
BROKER_NAME_URL="nats://localhost:4222"
cp "$NODE_DIR/config/va.yaml" "$RUN_ROOT/va.yaml.ip-broker"
sed -i "/^broker:/,/^[^[:space:]#]/ s#^\([[:space:]]*url:\).*#\1 '$BROKER_NAME_URL'#" \
  "$NODE_DIR/config/va.yaml"
run_installer success named-broker VA_REGISTER=0 START=0 VA_API_AUTHORIZATION=
grep -Eq 'broker localhost resolves to 127\.0\.0\.1' "$LAST_LOG" \
  || die 'a named broker was not resolved'
cp "$RUN_ROOT/va.yaml.ip-broker" "$NODE_DIR/config/va.yaml"
pass 'a broker named by DNS is resolved before the node starts'

run_installer success start-voip \
  VA_REGISTER=0 START=1 VA_API_AUTHORIZATION=
NODE_UP=1
grep -Fq 'replacing the running node container' "$LAST_LOG" \
  || die 'the pre-existing va-voip container was not replaced'
[[ $(docker inspect va-voip --format '{{.Config.Image}}') == "$(sed -n 's/^VA_VOIP_IMAGE=//p' "$NODE_DIR/.env")" ]] \
  || die 'the running va-voip is not the image the installer recorded'
rm -rf -- "$STALE_DIR"
pass 'an existing va-voip container is replaced by the one this install runs'
# The node reads the broker from the mounted YAML; the installer only checks
# the name resolves. .env is the secrets and the image, nothing else.
grep -Fq "$BROKER_URL" "$NODE_DIR/config/va.yaml" || die 'the broker is not in va.yaml'
grep -Eq '^VA_NATS_(URL|HOST)=' "$NODE_DIR/.env" && die '.env carries broker values it no longer needs'
[[ $(docker inspect va-voip --format '{{.HostConfig.NetworkMode}}') == host ]] \
  || die 'the node does not run on the host network'
[[ $(docker inspect va-voip --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}') == *"$NODE_DIR/config/va.yaml:/tmp/node.yaml"* ]] \
  || die 'the node does not mount this installation va.yaml at /tmp/node.yaml'
pass 'the node runs on the host network with this installation va.yaml'
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
