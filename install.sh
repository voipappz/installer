#!/bin/sh
# Public installer for one VoIPAppz VoIP node.
#
#   curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh
#
# The script is public. The platform image and every credential stay private.
set -eu

VA_VOIP_IMAGE="${VA_VOIP_IMAGE:-nirlevi/va-crystal:node}"
INSTALL_DIR="${INSTALL_DIR:-/opt/voipappz}"
VA_CONFIG="${VA_CONFIG:-}"
VA_API_URL="${VA_API_URL:-https://cloud.voipappz.io}"
VA_NATS_URL="${VA_NATS_URL:-}"
VA_REGISTER="${VA_REGISTER:-1}"
VA_CUSTOMER_UUID="${VA_CUSTOMER_UUID:-}"
VA_CUSTOMER_NAME="${VA_CUSTOMER_NAME:-}"
START="${START:-1}"

case "$VA_REGISTER" in 0|1) ;; *) printf '!! VA_REGISTER must be 0 or 1\n' >&2; exit 1 ;; esac
case "$START" in 0|1) ;; *) printf '!! START must be 0 or 1\n' >&2; exit 1 ;; esac
case "$INSTALL_DIR" in
  /*) ;;
  *) printf '!! INSTALL_DIR must be an absolute, specific directory\n' >&2; exit 1 ;;
esac

FS_AS_ROOT=0
DOCKER_AS_ROOT=0
CID=""
DOCKER_CONFIG_DIR=""
DOCKER_INSTALL_SCRIPT=""
API_BODY_FILE=""
PROVISIONING_GUARD=""
ENV_TEMP=""
TTY_STATE=""
REPLY=""

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

have_sudo() { command -v sudo >/dev/null 2>&1; }

root_cmd() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have_sudo; then
    sudo "$@"
  else
    return 1
  fi
}

fs_cmd() {
  if [ "$FS_AS_ROOT" = "1" ]; then root_cmd "$@"; else "$@"; fi
}

docker_cmd() {
  if [ "$DOCKER_AS_ROOT" = "1" ]; then root_cmd docker "$@"; else docker "$@"; fi
}

docker_auth_cmd() {
  if [ "$DOCKER_AS_ROOT" = "1" ]; then
    root_cmd docker --config "$DOCKER_CONFIG_DIR" "$@"
  else
    docker --config "$DOCKER_CONFIG_DIR" "$@"
  fi
}

docker_copy_cmd() {
  if [ "$DOCKER_AS_ROOT" = "1" ] || [ "$FS_AS_ROOT" = "1" ]; then
    root_cmd docker "$@"
  else
    docker "$@"
  fi
}

image_cli() {
  _va_path=$1
  shift
  if [ "$FS_AS_ROOT" = "1" ]; then
    docker_cmd run --rm --network host \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e "VA_PATH=$_va_path" \
      -v "$INSTALL_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" "$@"
  else
    docker_cmd run --rm --network host \
      --user "$(id -u):$(id -g)" \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e "VA_PATH=$_va_path" \
      -v "$INSTALL_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" "$@"
  fi
}

register_node_cli() (
  export VA_API_AUTHORIZATION
  if [ "$FS_AS_ROOT" = "1" ]; then
    docker_cmd run --rm --network host \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH=/work/config/va.yaml \
      -e VA_API_AUTHORIZATION \
      -v "$INSTALL_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" node register
  else
    docker_cmd run --rm --network host \
      --user "$(id -u):$(id -g)" \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH=/work/config/va.yaml \
      -e VA_API_AUTHORIZATION \
      -v "$INSTALL_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" node register
  fi
)

image_cli_tty() {
  if [ "$FS_AS_ROOT" = "1" ]; then
    docker_cmd run --rm -it --network host \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH= \
      -v "$INSTALL_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" setup < /dev/tty
  else
    docker_cmd run --rm -it --network host \
      --user "$(id -u):$(id -g)" \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH= \
      -v "$INSTALL_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" setup < /dev/tty
  fi
}

set_compose_env() {
  _env_key=$1
  _env_value=$2
  [ -n "$_env_value" ] || return 0
  validate_scalar "$_env_key" "$_env_value"
  ENV_TEMP="$(fs_cmd mktemp "$INSTALL_DIR/.env.tmp.XXXXXX")" \
    || die "could not update $INSTALL_DIR/.env"
  fs_cmd sed "/^${_env_key}=/d" "$INSTALL_DIR/.env" |
    fs_cmd tee "$ENV_TEMP" >/dev/null
  printf '%s=%s\n' "$_env_key" "$_env_value" |
    fs_cmd tee -a "$ENV_TEMP" >/dev/null
  fs_cmd chmod 0600 "$ENV_TEMP"
  fs_cmd mv -f -- "$ENV_TEMP" "$INSTALL_DIR/.env"
  ENV_TEMP=""
}

cleanup_docker_config() {
  case "${DOCKER_CONFIG_DIR:-}" in
    /tmp/voipappz-docker-auth.*)
      if [ "$DOCKER_AS_ROOT" = "1" ]; then
        root_cmd rm -rf -- "$DOCKER_CONFIG_DIR" 2>/dev/null || true
      else
        rm -rf -- "$DOCKER_CONFIG_DIR"
      fi
      ;;
  esac
  DOCKER_CONFIG_DIR=""
}

cleanup() {
  _status=$?
  set +e
  [ -z "$TTY_STATE" ] || stty "$TTY_STATE" < /dev/tty 2>/dev/null
  [ -z "$CID" ] || docker_cmd rm -f "$CID" >/dev/null 2>&1
  [ -z "$ENV_TEMP" ] || fs_cmd rm -f -- "$ENV_TEMP" 2>/dev/null
  cleanup_docker_config
  case "$DOCKER_INSTALL_SCRIPT" in
    /tmp/voipappz-docker-install.*) rm -f -- "$DOCKER_INSTALL_SCRIPT" ;;
  esac
  case "$API_BODY_FILE" in
    /tmp/voipappz-api-response.*) rm -f -- "$API_BODY_FILE" ;;
  esac
  VA_REGISTRY_TOKEN=""
  VA_API_AUTHORIZATION=""
  unset VA_REGISTRY_TOKEN VA_API_AUTHORIZATION 2>/dev/null
  exit "$_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

has_tty() { [ -c /dev/tty ] && (: < /dev/tty) 2>/dev/null; }

ask() {
  _prompt=$1
  _silent=${2:-}
  has_tty || die "no terminal for $_prompt; set the documented environment variable"
  REPLY=""
  if [ -n "$_silent" ]; then
    TTY_STATE="$(stty -g < /dev/tty)" || die "cannot disable terminal echo"
    stty -echo < /dev/tty
  fi
  printf '  %s: ' "$_prompt" > /dev/tty
  if ! IFS= read -r REPLY < /dev/tty; then
    [ -z "$TTY_STATE" ] || stty "$TTY_STATE" < /dev/tty 2>/dev/null
    TTY_STATE=""
    die "could not read $_prompt"
  fi
  if [ -n "$_silent" ]; then
    stty "$TTY_STATE" < /dev/tty 2>/dev/null
    TTY_STATE=""
    printf '\n' > /dev/tty
  fi
}

prepare_install_dir() {
  if mkdir -p "$INSTALL_DIR" 2>/dev/null && [ -w "$INSTALL_DIR" ]; then
    return 0
  fi
  root_cmd mkdir -p "$INSTALL_DIR" || die "cannot write $INSTALL_DIR and sudo is unavailable"
  FS_AS_ROOT=1
}

ensure_host_tools() {
  _packages=""
  command -v curl >/dev/null 2>&1 || _packages="curl ca-certificates"
  if [ "$VA_REGISTER" = "1" ] && ! command -v jq >/dev/null 2>&1; then
    _packages="$_packages jq"
  fi
  [ -n "$_packages" ] || return 0
  command -v apt-get >/dev/null 2>&1 \
    || die "missing required tools ($_packages); install them and retry"
  say "installing required host tools: $_packages"
  root_cmd apt-get update -qq || die "could not update apt package metadata"
  # Package names above are fixed by this script.
  # shellcheck disable=SC2086
  root_cmd apt-get install -y -qq $_packages >/dev/null \
    || die "could not install required host tools"
}

pick_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER_AS_ROOT=0
  elif have_sudo && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_AS_ROOT=1
  elif have_sudo; then
    say "Docker needs elevation; sudo may ask for your password"
    sudo docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon"
    DOCKER_AS_ROOT=1
  else
    die "cannot talk to the Docker daemon"
  fi
}

registry_of() {
  case "$1" in
    */*)
      _first=${1%%/*}
      case "$_first" in localhost|*.*|*:*) printf '%s' "$_first" ;; *) printf '' ;; esac
      ;;
    *) printf '' ;;
  esac
}

validate_scalar() {
  case "$2" in *"'"*) die "$1 contains a quote that cannot be added safely to va.yaml" ;; esac
  case "$2" in *"
"*) die "$1 contains a newline" ;; esac
  printf '%s' "$2" | LC_ALL=C grep -q '[[:cntrl:]]' \
    && die "$1 contains a control character"
  return 0
}

validate_authorization() {
  case "$VA_API_AUTHORIZATION" in
    "Basic "*) _credentials=${VA_API_AUTHORIZATION#Basic } ;;
    *) die "VA_API_AUTHORIZATION must be a complete Account Basic authorization value" ;;
  esac
  [ -n "$_credentials" ] || die "VA_API_AUTHORIZATION has no credentials"
  case "$_credentials" in *[!A-Za-z0-9+/=]*) die "VA_API_AUTHORIZATION is malformed" ;; esac
}

validate_api_url() {
  case "$VA_API_URL" in
    https://*) ;;
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) ;;
    *) die "mothership URL must use HTTPS (HTTP is allowed only on loopback)" ;;
  esac
}

api_request() {
  _method=$1
  _path=$2
  shift 2
  : > "$API_BODY_FILE"
  if ! API_STATUS="$(
    printf 'header = "Authorization: %s"\nheader = "Accept: application/json"\n' "$VA_API_AUTHORIZATION" |
      curl --config - --silent --show-error --connect-timeout 10 --max-time 45 \
        --request "$_method" --output "$API_BODY_FILE" --write-out '%{http_code}' \
        "$@" --url "${API_ROOT}${_path}"
  )"; then
    API_BODY=""
    return 1
  fi
  API_BODY="$(cat "$API_BODY_FILE")"
}

api_error() {
  case "$API_STATUS" in
    401) die "mothership rejected the Account Basic authorization (HTTP 401)" ;;
    403) die "this Account is not allowed to $1 (HTTP 403)" ;;
    *) die "mothership could not $1 (HTTP $API_STATUS)" ;;
  esac
}

load_customers() {
  api_request GET "/customers" || die "could not reach the mothership while listing customers"
  [ "$API_STATUS" = "200" ] || api_error "list customers"
  printf '%s' "$API_BODY" | jq -e 'type == "array" and all(.[]; type == "object")' >/dev/null \
    || die "mothership returned an invalid customer list"
  CUSTOMERS_JSON=$API_BODY
}

customer_by_uuid() {
  printf '%s' "$CUSTOMERS_JSON" |
    jq -c --arg value "$1" '[.[] | select(.uuid == $value)] | if length == 1 then .[0] else empty end'
}

customer_by_name() {
  printf '%s' "$CUSTOMERS_JSON" |
    jq -c --arg value "$1" '[.[] | select(.name == $value)] | if length == 1 then .[0] else empty end'
}

link_customer() {
  _customer=$1
  printf '%s' "$_customer" |
    jq -e '(.uuid | type == "string") and (.enabled | type == "boolean") and
           ((.node_uuid == null) or (.node_uuid | type == "string"))' >/dev/null \
    || die "mothership returned an invalid customer record"
  _uuid="$(printf '%s' "$_customer" | jq -r '.uuid')"
  _enabled="$(printf '%s' "$_customer" | jq -r '.enabled')"
  _linked_node="$(printf '%s' "$_customer" | jq -r '.node_uuid // ""')"
  [ "$_enabled" = "true" ] || die "customer $_uuid is disabled"

  if [ -z "$_linked_node" ]; then
    say "linking customer $_uuid to node $NODE_UUID"
    api_request PATCH "/customers/$_uuid" --data-urlencode "node_uuid=$NODE_UUID" \
      || die "could not reach the mothership while linking the customer"
    [ "$API_STATUS" = "200" ] || api_error "link customer $_uuid"
    _confirmed="$(printf '%s' "$API_BODY" | jq -r --arg node "$NODE_UUID" \
      'select(.node_uuid == $node) | .uuid // empty')" \
      || die "mothership returned an invalid customer update"
    [ "$_confirmed" = "$_uuid" ] || die "mothership did not confirm the customer/node link"
  elif [ "$_linked_node" = "$NODE_UUID" ]; then
    say "customer $_uuid is already linked to this node"
  else
    die "customer $_uuid is already linked to node $_linked_node; refusing to move it"
  fi
  SELECTED_CUSTOMER_UUID=$_uuid
}

create_customer() {
  _name=$1
  [ -n "$_name" ] || die "new customer name cannot be empty"
  printf '%s' "$_name" | LC_ALL=C grep -q '[[:cntrl:]]' \
    && die "new customer name contains a control character"

  say "creating customer $_name"
  printf '%s\n' "$_name" | fs_cmd tee "$PROVISIONING_GUARD" >/dev/null
  fs_cmd chmod 0600 "$PROVISIONING_GUARD"
  api_request POST "/customers" --data-urlencode "name=$_name" \
    --data-urlencode "enabled=true" --data-urlencode "node_uuid=$NODE_UUID" \
    || die "new-customer result is unknown; re-run with the same VA_CUSTOMER_NAME"

  case "$API_STATUS" in
    201)
      printf '%s' "$API_BODY" | jq -e 'type == "object"' >/dev/null \
        || die "mothership returned invalid JSON after creating the customer"
      _init_error="$(printf '%s' "$API_BODY" | jq -r '.init_error // empty')" \
        || die "mothership returned invalid JSON after creating the customer"
      _uuid="$(printf '%s' "$API_BODY" | jq -r '.uuid // empty')"
      _linked_node="$(printf '%s' "$API_BODY" | jq -r '.node_uuid // empty')"
      [ -n "$_uuid" ] || die "mothership created a customer but returned no UUID"
      [ -z "$_init_error" ] \
        || die "customer $_uuid was created, but Customer::Init failed: $_init_error"
      [ "$_linked_node" = "$NODE_UUID" ] \
        || die "customer $_uuid was created without the requested node link"
      fs_cmd rm -f -- "$PROVISIONING_GUARD" \
        || die "customer $_uuid is ready, but the local initialization marker could not be cleared"
      SELECTED_CUSTOMER_UUID=$_uuid
      say "customer $_uuid created and initialized"
      ;;
    406|409)
      die "customer creation conflicted; initialization state is uncertain (marker: $PROVISIONING_GUARD)"
      ;;
    *) api_error "create customer" ;;
  esac
}

resolve_customer() {
  [ -z "$VA_CUSTOMER_UUID" ] || [ -z "$VA_CUSTOMER_NAME" ] \
    || die "set VA_CUSTOMER_UUID or VA_CUSTOMER_NAME, not both"
  if [ -f "$PROVISIONING_GUARD" ]; then
    _pending="$(fs_cmd sed -n '1p' "$PROVISIONING_GUARD" 2>/dev/null || printf 'unknown')"
    die "customer '$_pending' has incomplete initialization; resolve it before removing $PROVISIONING_GUARD"
  fi
  load_customers

  if [ -n "$VA_CUSTOMER_UUID" ]; then
    _customer="$(customer_by_uuid "$VA_CUSTOMER_UUID")"
    [ -n "$_customer" ] || die "customer $VA_CUSTOMER_UUID is not visible to this Account"
    link_customer "$_customer"
    return
  fi

  if [ -n "$VA_CUSTOMER_NAME" ]; then
    _customer="$(customer_by_name "$VA_CUSTOMER_NAME")"
    if [ -n "$_customer" ]; then link_customer "$_customer"; else create_customer "$VA_CUSTOMER_NAME"; fi
    return
  fi

  _count="$(printf '%s' "$CUSTOMERS_JSON" | jq 'length')"
  case "$_count" in
    0)
      ask "new customer name"
      create_customer "$REPLY"
      ;;
    1)
      link_customer "$(printf '%s' "$CUSTOMERS_JSON" | jq -c '.[0]')"
      ;;
    *) die "this Account sees $_count customers; set VA_CUSTOMER_UUID or VA_CUSTOMER_NAME" ;;
  esac
}

prepare_install_dir
ensure_host_tools

printf '\nVoIPAppz VoIP node installer\n'

step "1/6  Docker"
if command -v docker >/dev/null 2>&1; then
  say "present ($(docker --version 2>/dev/null || printf 'version unavailable'))"
else
  say "installing Docker"
  DOCKER_INSTALL_SCRIPT="$(mktemp /tmp/voipappz-docker-install.XXXXXX)"
  curl -fsSL https://get.docker.com -o "$DOCKER_INSTALL_SCRIPT" \
    || die "could not download the Docker installer"
  root_cmd sh "$DOCKER_INSTALL_SCRIPT" >/dev/null || die "Docker installation failed"
  rm -f -- "$DOCKER_INSTALL_SCRIPT"
  DOCKER_INSTALL_SCRIPT=""
fi
pick_docker
docker_cmd compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

step "2/6  Platform image"
if docker_cmd image inspect "$VA_VOIP_IMAGE" >/dev/null 2>&1; then
  say "$VA_VOIP_IMAGE is already present"
else
  if [ -z "${VA_REGISTRY_USER:-}" ]; then ask "Docker Hub user"; VA_REGISTRY_USER=$REPLY; fi
  if [ -z "${VA_REGISTRY_TOKEN:-}" ]; then ask "Docker Hub token" silent; VA_REGISTRY_TOKEN=$REPLY; fi
  if [ -z "$VA_REGISTRY_USER" ] || [ -z "$VA_REGISTRY_TOKEN" ]; then
    die "Docker Hub user and token are required to pull $VA_VOIP_IMAGE"
  fi

  DOCKER_CONFIG_DIR="$(mktemp -d /tmp/voipappz-docker-auth.XXXXXX)"
  chmod 0700 "$DOCKER_CONFIG_DIR"
  REGISTRY="$(registry_of "$VA_VOIP_IMAGE")"
  say "logging in to ${REGISTRY:-Docker Hub} with a temporary Docker config"
  if [ -n "$REGISTRY" ]; then
    printf '%s' "$VA_REGISTRY_TOKEN" |
      docker_auth_cmd login "$REGISTRY" -u "$VA_REGISTRY_USER" --password-stdin >/dev/null 2>&1
  else
    printf '%s' "$VA_REGISTRY_TOKEN" |
      docker_auth_cmd login -u "$VA_REGISTRY_USER" --password-stdin >/dev/null 2>&1
  fi || die "registry login was rejected"
  VA_REGISTRY_TOKEN=""
  unset VA_REGISTRY_TOKEN 2>/dev/null
  say "pulling $VA_VOIP_IMAGE"
  docker_auth_cmd pull -q "$VA_VOIP_IMAGE" >/dev/null || die "could not pull $VA_VOIP_IMAGE"
  cleanup_docker_config
fi
VA_REGISTRY_TOKEN=""
unset VA_REGISTRY_TOKEN VA_REGISTRY_USER 2>/dev/null

step "3/6  Node stack"
CID="$(docker_cmd create "$VA_VOIP_IMAGE" true)" || die "could not open $VA_VOIP_IMAGE"
fs_cmd mkdir -p "$INSTALL_DIR/config"
docker_copy_cmd cp "$CID:/stack/." "$INSTALL_DIR/" \
  || die "$VA_VOIP_IMAGE has no bundled node stack"
docker_cmd rm -f "$CID" >/dev/null
CID=""
[ -f "$INSTALL_DIR/docker-compose.yaml" ] || die "the bundled stack has no docker-compose.yaml"
grep -Fq -- './config/va.yaml:/tmp/node.yaml' "$INSTALL_DIR/docker-compose.yaml" \
  || die "the bundled stack does not mount config/va.yaml at /tmp/node.yaml"
docker_cmd run --rm --entrypoint voipappz "$VA_VOIP_IMAGE" node --help >/dev/null \
  || die "$VA_VOIP_IMAGE has no working node CLI"
say "installed the stack and verified its in-container CLI"

step "4/6  va.yaml"
VA_YAML="$INSTALL_DIR/config/va.yaml"
PROVISIONING_GUARD="$INSTALL_DIR/.customer-provisioning-incomplete"
if [ -n "$VA_CONFIG" ]; then
  [ -f "$VA_CONFIG" ] || die "no va.yaml at $VA_CONFIG"
  if [ -f "$VA_YAML" ] && cmp -s "$VA_CONFIG" "$VA_YAML"; then
    say "va.yaml is already current"
  else
    fs_cmd cp "$VA_CONFIG" "$VA_YAML"
    say "installed $VA_CONFIG -> $VA_YAML"
  fi
elif [ -f "$VA_YAML" ]; then
  say "keeping $VA_YAML"
else
  has_tty || die "no va.yaml and no terminal; pass VA_CONFIG=/path/to/va.yaml"
  say "running the existing setup wizard"
  image_cli_tty
fi
[ -f "$VA_YAML" ] || die "setup did not create $VA_YAML"
fs_cmd chmod 0644 "$VA_YAML"

if ! grep -Eq '^[[:space:]]*mothership:' "$VA_YAML"; then
  validate_scalar "VA_API_URL" "$VA_API_URL"
  printf "\nmothership:\n  url: '%s'\n" "$VA_API_URL" | fs_cmd tee -a "$VA_YAML" >/dev/null
fi
if [ -n "$VA_NATS_URL" ] && ! grep -Eq '^[[:space:]]*broker:' "$VA_YAML"; then
  validate_scalar "VA_NATS_URL" "$VA_NATS_URL"
  printf "\nbroker:\n  url: '%s'\n" "$VA_NATS_URL" | fs_cmd tee -a "$VA_YAML" >/dev/null
fi
if ! grep -Eq '^[[:space:]]*broker:' "$VA_YAML"; then
  [ "$START" = "0" ] || die "va.yaml has no broker; add broker.url or set VA_NATS_URL"
  say "WARNING: va.yaml has no broker; it must be configured before the node starts"
fi

# Run the existing setup implementation in the image. This normalizes the
# supplied YAML and creates the Compose .env without installing a second CLI.
image_cli "" setup --ci >/dev/null \
  || die "the node CLI could not finish setup"

NODE_ENV="$(image_cli "/work/config/va.yaml" env --export 2>/dev/null)" \
  || die "the image CLI could not parse $VA_YAML"
NODE_UUID="$(printf '%s\n' "$NODE_ENV" | sed -n 's/^VA_NODE_UUID=//p' | head -1)"
CONFIG_API_URL="$(printf '%s\n' "$NODE_ENV" | sed -n 's/^VA_API_URL=//p' | head -1)"
CONFIG_NATS_URL="$(printf '%s\n' "$NODE_ENV" | sed -n 's/^VA_NATS_URL=//p' | head -1)"
NODE_ENV=""
[ -n "$NODE_UUID" ] || die "va.yaml did not produce a node UUID"
[ -z "$CONFIG_API_URL" ] || VA_API_URL=$CONFIG_API_URL
set_compose_env VA_API_URL "$CONFIG_API_URL"
set_compose_env VA_NATS_URL "$CONFIG_NATS_URL"

step "5/6  Registration"
SELECTED_CUSTOMER_UUID=""
if [ "$VA_REGISTER" = "1" ]; then
  if [ -z "${VA_API_AUTHORIZATION:-}" ]; then
    ask "Account Basic authorization (Basic ...)" silent
    VA_API_AUTHORIZATION=$REPLY
  fi
  validate_authorization
  validate_api_url
  _api_base=${VA_API_URL%/}
  case "$_api_base" in */api) API_ROOT=$_api_base ;; *) API_ROOT="$_api_base/api" ;; esac

  say "registering node $NODE_UUID through the existing CLI"
  register_node_cli \
    || die "node registration failed; no customer change was attempted"

  API_BODY_FILE="$(mktemp /tmp/voipappz-api-response.XXXXXX)"
  chmod 0600 "$API_BODY_FILE"
  API_STATUS=""
  API_BODY=""
  CUSTOMERS_JSON=""
  resolve_customer
  VA_API_AUTHORIZATION=""
  unset VA_API_AUTHORIZATION 2>/dev/null
  rm -f -- "$API_BODY_FILE"
  API_BODY_FILE=""
else
  say "skipped (VA_REGISTER=0)"
fi
VA_API_AUTHORIZATION=""
unset VA_API_AUTHORIZATION 2>/dev/null

step "6/6  VoIP plane"
if [ "$START" = "1" ]; then
  (cd "$INSTALL_DIR" && docker_cmd compose --profile voip up -d) \
    || die "could not start the VoIP profile"

  _attempt=0
  while [ "$_attempt" -lt 40 ]; do
    curl -fsS --max-time 3 http://127.0.0.1:4000/health >/dev/null 2>&1 && break
    docker_cmd inspect va-voip >/dev/null 2>&1 \
      || die "va-voip stopped before becoming healthy; run: docker logs va-voip"
    _attempt=$((_attempt + 1))
    sleep 3
  done
  curl -fsS --max-time 3 http://127.0.0.1:4000/health >/dev/null 2>&1 \
    || die "va-voip did not become healthy; run: docker logs va-voip"
  docker_cmd exec -e VA_CONFIG_PATH=/tmp/node.yaml \
    va-voip voipappz sbc egress sync >/dev/null \
    || die "the node CLI could not apply va.yaml to Kamailio"

  _attempt=0
  while [ "$_attempt" -lt 40 ]; do
    docker_cmd exec va-voip voipappz health >/dev/null 2>&1 && break
    _attempt=$((_attempt + 1))
    sleep 3
  done
  docker_cmd exec va-voip voipappz health >/dev/null 2>&1 \
    || die "va-voip did not pass node health; run: docker exec va-voip voipappz health"
  say "va-voip is healthy"
else
  say "installed but not started (START=0)"
fi

printf '\n\033[1mVoIPAppz installation complete\033[0m\n'
say "node:      $NODE_UUID"
[ -z "$SELECTED_CUSTOMER_UUID" ] || say "customer:  $SELECTED_CUSTOMER_UUID"
say "va.yaml:   $VA_YAML -> /tmp/node.yaml (Docker bind mount)"
if [ "$START" = "1" ]; then
  say "container: va-voip"
  say "health:    http://127.0.0.1:4000/health"
else
  say "start:     cd $INSTALL_DIR && docker compose --profile voip up -d"
fi
say "CLI:       docker exec va-voip voipappz --help"
