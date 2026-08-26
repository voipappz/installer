#!/bin/sh
# Public installer for one VoIPAppz VoIP node.
#
#   curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/install.sh | sh
#
# The script is public. The platform image and every credential stay private.
set -eu

VA_VOIP_IMAGE="${VA_VOIP_IMAGE:-nirlevi/va-crystal:node}"
VA_IMAGE_ARCHIVE="${VA_IMAGE_ARCHIVE:-}"
# Where `make s3-publish` in va-crystal puts the newest proven image archive.
VA_IMAGE_URL="${VA_IMAGE_URL:-https://voipappz-assets-il.s3.il-central-1.amazonaws.com/images/va-crystal-node-latest.tar.gz}"
# dockerhub | s3 | archive — unattended choice of image source. Empty means:
# VA_IMAGE_ARCHIVE if set, else registry credentials if set, else ask.
VA_IMAGE_SOURCE="${VA_IMAGE_SOURCE:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/voipappz}"
VA_CONFIG="${VA_CONFIG:-}"
VA_CA_BUNDLE="${VA_CA_BUNDLE:-}"
# 1 once the mothership's certificate was pinned (saved as presented to
# config/ca-bundle.pem). The CLI then verifies against that pin and checks no
# hostname; the installer's own customer API calls follow the same rule.
PINNED=0
CA_BUNDLE=""
if [ -n "${VA_API_URL:-}" ]; then VA_API_URL_EXPLICIT=1; else VA_API_URL_EXPLICIT=0; fi
VA_API_URL="${VA_API_URL:-https://cloud.voipappz.io}"
VA_NATS_URL="${VA_NATS_URL:-}"
VA_NATS_HOST="${VA_NATS_HOST:-}"
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
case "$VA_IMAGE_SOURCE" in
  ''|dockerhub|archive) ;;
  s3) [ -n "$VA_IMAGE_ARCHIVE" ] || VA_IMAGE_ARCHIVE=$VA_IMAGE_URL ;;
  *) printf '!! VA_IMAGE_SOURCE must be dockerhub, s3 or archive\n' >&2; exit 1 ;;
esac
if [ "$VA_IMAGE_SOURCE" = "archive" ] && [ -z "$VA_IMAGE_ARCHIVE" ]; then
  printf '!! VA_IMAGE_SOURCE=archive needs VA_IMAGE_ARCHIVE=<path or URL>\n' >&2; exit 1
fi
[ "$VA_IMAGE_SOURCE" != "dockerhub" ] || VA_IMAGE_ARCHIVE=""
# A saved image archive (.tar or .tar.gz): an absolute local path, or an
# http(s) URL that is downloaded to a temporary file first.
if [ -n "$VA_IMAGE_ARCHIVE" ]; then
  case "$VA_IMAGE_ARCHIVE" in
    http://*|https://*) ;;
    /*)
      if [ ! -f "$VA_IMAGE_ARCHIVE" ] || [ ! -r "$VA_IMAGE_ARCHIVE" ]; then
        printf '!! VA_IMAGE_ARCHIVE is not a readable file: %s\n' "$VA_IMAGE_ARCHIVE" >&2
        exit 1
      fi ;;
    *) printf '!! VA_IMAGE_ARCHIVE must be an absolute path or an http(s) URL of a saved image archive\n' >&2; exit 1 ;;
  esac
fi

FS_AS_ROOT=0
DOCKER_AS_ROOT=0
CID=""
DOCKER_CONFIG_DIR=""
DOCKER_INSTALL_SCRIPT=""
API_BODY_FILE=""
ARCHIVE_DOWNLOAD=""
WIZARD_RAN=0
PROVISIONING_GUARD=""
WORK_DIR=""
ENV_TEMP=""
TTY_STATE=""
REPLY=""
ACCOUNT_EMAIL_INPUT=""
ACCOUNT_PASSWORD_INPUT=""
ACCOUNT_BASIC_INPUT=""

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


image_cli() {
  _va_path=$1
  shift
  if [ "$FS_AS_ROOT" = "1" ]; then
    docker_cmd run --rm --network host \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e "VA_PATH=$_va_path" \
      -v "$WORK_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" "$@"
  else
    docker_cmd run --rm --network host \
      --user "$(id -u):$(id -g)" \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e "VA_PATH=$_va_path" \
      -v "$WORK_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" "$@"
  fi
}

# The registration container gets the Account authorization through its
# environment, but that environment must be built INSIDE the docker command:
# when Docker needs sudo, sudo resets the caller's environment and a plain
# `-e VA_API_AUTHORIZATION` forwards nothing. The value crosses the sudo
# boundary on stdin — never as an argument, where `ps` would show it.
docker_with_authorization() {
  if [ "$DOCKER_AS_ROOT" = "1" ]; then
    printf '%s' "$VA_API_AUTHORIZATION" |
      sudo sh -c 'VA_API_AUTHORIZATION=$(cat); export VA_API_AUTHORIZATION; exec "$@"' sh docker "$@"
  else
    printf '%s' "$VA_API_AUTHORIZATION" |
      sh -c 'VA_API_AUTHORIZATION=$(cat); export VA_API_AUTHORIZATION; exec "$@"' sh docker "$@"
  fi
}

register_node_cli() {
  if [ -n "$CA_BUNDLE" ]; then _ssl_cert=/work/config/ca-bundle.pem; else _ssl_cert=""; fi
  if [ "$FS_AS_ROOT" = "1" ]; then
    docker_with_authorization run --rm --network host \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH=/work/config/va.yaml \
      -e VA_API_AUTHORIZATION -e "SSL_CERT_FILE=$_ssl_cert" \
      -v "$WORK_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" node register
  else
    docker_with_authorization run --rm --network host \
      --user "$(id -u):$(id -g)" \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH=/work/config/va.yaml \
      -e VA_API_AUTHORIZATION -e "SSL_CERT_FILE=$_ssl_cert" \
      -v "$WORK_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" node register
  fi
}

# The image CLI has two wizards. With VA_PATH set it runs the node-only one
# (name, internal IP, external IP) and writes just the mounted YAML; with
# VA_PATH empty it runs the full host wizard (organization, domain, TLS/acme,
# alerts), which belongs to the mothership. A node install must get the former.
image_cli_tty() {
  if [ "$FS_AS_ROOT" = "1" ]; then
    docker_cmd run --rm -it --network host \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH=/work/config/va.yaml \
      -v "$WORK_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" setup < /dev/tty
  else
    docker_cmd run --rm -it --network host \
      --user "$(id -u):$(id -g)" \
      --entrypoint voipappz \
      -e VA_PROJECT_DIR=/work -e VA_PATH=/work/config/va.yaml \
      -v "$WORK_DIR:/work" -w /work \
      "$VA_VOIP_IMAGE" setup < /dev/tty
  fi
}

# One value in $INSTALL_DIR/.env, the installer's record of what this node
# runs with. Compose is gone (the image is started with `docker run`), so this
# file is no longer interpolated by anything — it is read back by the next run
# and by `docker run -e` for the three secrets the image cannot derive.
set_env_value() {
  _env_key=$1
  _env_value=$2
  [ -n "$_env_value" ] || return 0
  validate_scalar "$_env_key" "$_env_value"
  ENV_TEMP="$(fs_cmd mktemp "$WORK_DIR/.env.tmp.XXXXXX")" \
    || die "could not update $WORK_DIR/.env"
  fs_cmd sed "/^${_env_key}=/d" "$WORK_DIR/.env" |
    fs_cmd tee "$ENV_TEMP" >/dev/null
  printf '%s=%s\n' "$_env_key" "$_env_value" |
    fs_cmd tee -a "$ENV_TEMP" >/dev/null
  fs_cmd chmod 0600 "$ENV_TEMP"
  fs_cmd mv -f -- "$ENV_TEMP" "$WORK_DIR/.env"
  ENV_TEMP=""
}

# nats://user:token@host:4222 -> host. Compose needs the bare host for the voip
# service's `nats:${VA_NATS_HOST}` mapping.
host_of_url() {
  _rest=${1#*://}
  _rest=${_rest##*@}
  _rest=${_rest%%/*}
  printf '%s' "${_rest%%:*}"
}

# Compose maps the broker into the voip service with extra_hosts, and Docker
# refuses a name there ("invalid IP address in add-host"), so a broker named by
# DNS has to be resolved once, at install time.
resolve_host() {
  case "$1" in
    '') return 0 ;;
    *[!0-9.]*) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  _ip="$(getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1; exit }')"
  [ -n "$_ip" ] || _ip="$(getent hosts "$1" 2>/dev/null | awk '{ print $1; exit }')"
  printf '%s' "$_ip"
}

yaml_api_url() {
  fs_cmd sed -n '/^mothership:/,/^[^[:space:]#]/{ s/^[[:space:]]*url:[[:space:]]*//p; }' "$VA_YAML" |
    head -1 | tr -d "\"'" | tr -d '[:space:]'
}

yaml_broker_url() {
  fs_cmd sed -n '/^broker:/,/^[^[:space:]#]/{ s/^[[:space:]]*url:[[:space:]]*//p; }' "$VA_YAML" |
    head -1 | tr -d "\"'" | tr -d '[:space:]'
}

# Set <section>.url in va.yaml: replace the value in place (also when it is
# empty), or append the section when it is missing.
set_yaml_section_url() {
  _section=$1
  _name=$2
  _url=$3
  validate_scalar "$_name" "$_url"
  ENV_TEMP="$(fs_cmd mktemp "$WORK_DIR/config/.va.yaml.tmp.XXXXXX")" \
    || die "could not update $VA_YAML"
  # shellcheck disable=SC2016
  fs_cmd awk -v url="$_url" -v section="$_section" '
    function emit_url() { print "  url: \047" url "\047"; wrote = 1 }
    $0 ~ "^" section ":[[:space:]]*(#.*)?$" {
      in_section = 1
      saw_section = 1
      print
      next
    }
    in_section && /^[^[:space:]#]/ {
      if (!wrote) emit_url()
      in_section = 0
    }
    in_section && /^[[:space:]]+url:[[:space:]]*/ {
      if (!wrote) emit_url()
      next
    }
    { print }
    END {
      if (in_section && !wrote) emit_url()
      if (!saw_section) {
        print ""
        print section ":"
        emit_url()
      }
    }
  ' "$VA_YAML" | fs_cmd tee "$ENV_TEMP" >/dev/null
  fs_cmd chmod 0644 "$ENV_TEMP"
  fs_cmd mv -f -- "$ENV_TEMP" "$VA_YAML"
  ENV_TEMP=""
}

set_yaml_api_url() { set_yaml_section_url mothership VA_API_URL "$1"; }
set_yaml_broker_url() { set_yaml_section_url broker VA_NATS_URL "$1"; }

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
  case "$WORK_DIR" in
    /tmp/voipappz-install.*) rm -rf -- "$WORK_DIR" 2>/dev/null || root_cmd rm -rf -- "$WORK_DIR" 2>/dev/null ;;
  esac
  case "$DOCKER_INSTALL_SCRIPT" in
    /tmp/voipappz-docker-install.*) rm -f -- "$DOCKER_INSTALL_SCRIPT" ;;
  esac
  case "$API_BODY_FILE" in
    /tmp/voipappz-api-response.*) rm -f -- "$API_BODY_FILE" ;;
  esac
  case "$ARCHIVE_DOWNLOAD" in
    /tmp/voipappz-image-archive.*) rm -f -- "$ARCHIVE_DOWNLOAD" "$ARCHIVE_DOWNLOAD.sha256" ;;
  esac
  VA_REGISTRY_TOKEN=""
  VA_API_AUTHORIZATION=""
  VA_API_EMAIL=""
  VA_API_PASSWORD=""
  ACCOUNT_EMAIL_INPUT=""
  ACCOUNT_PASSWORD_INPUT=""
  ACCOUNT_BASIC_INPUT=""
  REPLY=""
  unset VA_REGISTRY_TOKEN VA_API_AUTHORIZATION VA_API_EMAIL VA_API_PASSWORD 2>/dev/null
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
  printf '  \033[1m%s\033[0m: ' "$_prompt" > /dev/tty
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

# Interactive image source. Unattended installs pick the source through
# VA_IMAGE_ARCHIVE or VA_REGISTRY_USER/VA_REGISTRY_TOKEN and never see this.
choose_image_source() {
  [ -z "$VA_IMAGE_ARCHIVE" ] || return 0
  [ -z "$VA_IMAGE_SOURCE" ] || return 0
  [ -z "${VA_REGISTRY_USER:-}" ] && [ -z "${VA_REGISTRY_TOKEN:-}" ] || return 0
  has_tty || return 0
  printf '  Image source:\n    1) pull %s from Docker Hub (needs a Docker Hub user + token)\n    2) download the latest image archive from Amazon S3\n    3) load a docker-save archive (.tar or .tar.gz) from a local path or URL\n' \
    "$VA_VOIP_IMAGE" > /dev/tty
  while :; do
    ask "Choose 1, 2 or 3 [2]"
    case "$REPLY" in
      1) return 0 ;;
      ''|2) VA_IMAGE_ARCHIVE=$VA_IMAGE_URL; return 0 ;;
      3) break ;;
      *) printf '  enter 1, 2 or 3\n' > /dev/tty ;;
    esac
  done
  while :; do
    ask "Absolute path or http(s) URL of the image archive"
    case "$REPLY" in
      http://*|https://*) VA_IMAGE_ARCHIVE=$REPLY; return 0 ;;
      /*) if [ -f "$REPLY" ] && [ -r "$REPLY" ]; then VA_IMAGE_ARCHIVE=$REPLY; return 0; fi
          printf '  not a readable file: %s\n' "$REPLY" > /dev/tty ;;
      *)  printf '  enter an absolute path or an http(s) URL\n' > /dev/tty ;;
    esac
  done
}

set_account_authorization() {
  ACCOUNT_EMAIL_INPUT=${VA_API_EMAIL:-}
  ACCOUNT_PASSWORD_INPUT=${VA_API_PASSWORD:-}

  # An Account token is its Basic authorization key (the API authenticates
  # Accounts with Basic only). Accepted with or without the "Basic " prefix;
  # empty falls back to email + password, which build the same value.
  if [ -z "$ACCOUNT_EMAIL_INPUT" ] && [ -z "$ACCOUNT_PASSWORD_INPUT" ]; then
    ask "Account token (input hidden; empty = use email + password)" silent
    ACCOUNT_BASIC_INPUT=$REPLY
    case "$ACCOUNT_BASIC_INPUT" in "Basic "*) ACCOUNT_BASIC_INPUT=${ACCOUNT_BASIC_INPUT#Basic } ;; esac
    if [ -n "$ACCOUNT_BASIC_INPUT" ]; then
      printf '%s' "$ACCOUNT_BASIC_INPUT" | LC_ALL=C grep -Eq '^[A-Za-z0-9+/=]+$' \
        || die "Account token must be the Basic authorization key (base64)"
      VA_API_AUTHORIZATION="Basic $ACCOUNT_BASIC_INPUT"
      ACCOUNT_BASIC_INPUT=""
      REPLY=""
      return 0
    fi
  fi

  while [ -z "$ACCOUNT_EMAIL_INPUT" ]; do
    ask "Account email"
    ACCOUNT_EMAIL_INPUT=$REPLY
    [ -n "$ACCOUNT_EMAIL_INPUT" ] || say "email cannot be empty; try again"
  done
  case "$ACCOUNT_EMAIL_INPUT" in *:*) die "Account email cannot contain ':'" ;; esac
  printf '%s' "$ACCOUNT_EMAIL_INPUT" | LC_ALL=C grep -q '[[:cntrl:]]' \
    && die "Account email contains a control character"

  while [ -z "$ACCOUNT_PASSWORD_INPUT" ]; do
    ask "Account password (input hidden)" silent
    ACCOUNT_PASSWORD_INPUT=$REPLY
    [ -n "$ACCOUNT_PASSWORD_INPUT" ] || say "password cannot be empty; try again"
  done
  printf '%s' "$ACCOUNT_PASSWORD_INPUT" | LC_ALL=C grep -q '[[:cntrl:]]' \
    && die "Account password contains a control character"

  ACCOUNT_BASIC_INPUT="$(
    printf '%s:%s' "$ACCOUNT_EMAIL_INPUT" "$ACCOUNT_PASSWORD_INPUT" | base64 | tr -d '\n'
  )"
  VA_API_AUTHORIZATION="Basic $ACCOUNT_BASIC_INPUT"
  ACCOUNT_EMAIL_INPUT=""
  ACCOUNT_PASSWORD_INPUT=""
  ACCOUNT_BASIC_INPUT=""
  VA_API_EMAIL=""
  VA_API_PASSWORD=""
  REPLY=""
  unset VA_API_EMAIL VA_API_PASSWORD 2>/dev/null
}

prepare_install_dir() {
  [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ] && return 0
  if [ ! -d "$INSTALL_DIR" ] && mkdir -p "$INSTALL_DIR" 2>/dev/null; then
    return 0
  fi
  root_cmd mkdir -p "$INSTALL_DIR" || die "cannot write $INSTALL_DIR and sudo is unavailable"
  FS_AS_ROOT=1
}

# Nothing is written to INSTALL_DIR until the node is registered. The stack,
# va.yaml, .env and CA bundle are built in a private temporary directory and
# copied over in one step at the end; a failed run leaves the installation
# exactly as it was. What an existing installation already has (its va.yaml,
# .env, CA bundle) is seeded into the work directory first, so reruns keep it.
stage_work_dir() {
  WORK_DIR="$(mktemp -d /tmp/voipappz-install.XXXXXX)" || die "could not create a work directory"
  chmod 0700 "$WORK_DIR"
  mkdir -p "$WORK_DIR/config"
  for _f in config/va.yaml config/ca-bundle.pem .env; do
    [ -e "$INSTALL_DIR/$_f" ] || continue
    if [ -r "$INSTALL_DIR/$_f" ]; then
      cp "$INSTALL_DIR/$_f" "$WORK_DIR/$_f"
    else
      root_cmd cp "$INSTALL_DIR/$_f" "$WORK_DIR/$_f" || die "cannot read $INSTALL_DIR/$_f (sudo is required to reuse it)"
      root_cmd chown "$(id -u):$(id -g)" "$WORK_DIR/$_f" || die "cannot take over $WORK_DIR/$_f"
    fi
  done
}

# The one write to INSTALL_DIR: after registration succeeded. cp -R (not -a)
# so a root-owned installation gets root-owned files; modes are kept.
commit_install_dir() {
  prepare_install_dir
  fs_cmd cp -Rf "$WORK_DIR/." "$INSTALL_DIR/" || die "could not write $INSTALL_DIR"
  # Nothing from the compose era may survive here: the scaffold the image used
  # to carry is gone, and a stale compose file would start a second, different
  # node beside the one this installer runs.
  for _stale in docker-compose.yaml docker-compose.override.yaml; do
    [ -e "$INSTALL_DIR/$_stale" ] || continue
    fs_cmd rm -f -- "$INSTALL_DIR/$_stale"
    say "removed the obsolete $_stale (the image no longer ships a compose stack)"
  done
  rm -rf -- "$WORK_DIR" 2>/dev/null || root_cmd rm -rf -- "$WORK_DIR"
  WORK_DIR=""
  VA_YAML="$INSTALL_DIR/config/va.yaml"
  [ -z "$CA_BUNDLE" ] || CA_BUNDLE="$INSTALL_DIR/config/ca-bundle.pem"
  say "installed into $INSTALL_DIR"
}

ensure_host_tools() {
  _packages=""
  command -v curl >/dev/null 2>&1 || _packages="curl ca-certificates"
  if [ "$VA_REGISTER" = "1" ] && ! command -v jq >/dev/null 2>&1; then
    _packages="$_packages jq"
  fi
  if [ "$VA_REGISTER" = "1" ] && ! command -v openssl >/dev/null 2>&1; then
    _packages="$_packages openssl"
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

# Save the certificate chain the mothership presents as this node's trust
# anchor. Self-signed servers and private CAs both end up trusted this way,
# with verification still on — the CLI reads SSL_CERT_FILE, nothing is
# disabled. Called by the probe when the certificate is not in the store.
trust_mothership_certificate() {
  _host=${VA_API_URL#*://}; _host=${_host%%/*}
  case "$_host" in *:*) _port=${_host##*:}; _host=${_host%%:*} ;; *) _port=443 ;; esac
  _chain="$(openssl s_client -connect "$_host:$_port" -servername "$_host" -showcerts </dev/null 2>/dev/null |
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p')"
  [ -n "$_chain" ] || die "could not read a certificate from $_host:$_port"
  CA_BUNDLE="$WORK_DIR/config/ca-bundle.pem"
  printf '%s\n' "$_chain" | fs_cmd tee "$CA_BUNDLE" >/dev/null
  fs_cmd chmod 0644 "$CA_BUNDLE"
  say "trusting the certificate presented by $_host -> $CA_BUNDLE"
}

mothership_certificate_summary() {
  _host=${VA_API_URL#*://}; _host=${_host%%/*}
  case "$_host" in *:*) _port=${_host##*:}; _host=${_host%%:*} ;; *) _port=443 ;; esac
  openssl s_client -connect "$_host:$_port" -servername "$_host" </dev/null 2>/dev/null |
    openssl x509 -noout -subject -issuer -fingerprint -sha256 2>/dev/null | sed 's/^/    /'
}

# The mothership must answer before the CLI is asked to register. Three
# outcomes: it answers (any HTTP status — 401 is the normal unauthenticated
# reply); its certificate is not trusted (curl 60) — trust it on request; or
# it is unreachable — say why, and let a terminal correct the URL.
ensure_mothership_reachable() {
  _trusted=0
  while :; do
    _probe_base=${VA_API_URL%/}
    case "$_probe_base" in */api) ;; *) _probe_base="$_probe_base/api" ;; esac
    _rc=0
    _err="$( { [ -z "$CA_BUNDLE" ] || printf 'cacert = "%s"\n' "$CA_BUNDLE"; } |
      curl --config - -sS --max-time 15 -o /dev/null "$_probe_base/nodes" 2>&1 >/dev/null)" || _rc=$?
    case "$_rc" in
      0|22)
        say "mothership $VA_API_URL answers"
        return 0 ;;
      60|35)
        if [ "$_trusted" = "1" ]; then
          # The pin is saved; curl still checks the name, the CLI does not
          # (the pin IS the identity). An IP-addressed mothership with a
          # hostname certificate lands here and registers fine.
          say "the certificate is pinned; its name does not match $VA_API_URL, which the pin makes irrelevant"
          return 0
        fi
        # Trust as presented = PIN. The chain the mothership sends is saved to
        # config/ca-bundle.pem; the CLI verifies against exactly that and
        # refuses any other certificate. A self-signed mothership pins in one
        # step. A public certificate served without its intermediate cannot be
        # pinned from what it sends (nothing self-signed to anchor on): the CLI
        # says so, and VA_CA_BUNDLE=<the CA chain> is the answer.
        say "the certificate of $VA_API_URL is not in the trust store; pinning it as presented:"
        mothership_certificate_summary
        trust_mothership_certificate; _trusted=1; PINNED=1
        continue ;;
      *)
        say "cannot reach $VA_API_URL: ${_err:-curl exit $_rc}"
        has_tty || die "mothership unreachable; check VA_API_URL and the network"
        ask "Mothership URL [$VA_API_URL]"
        [ -z "$REPLY" ] || case "$REPLY" in
          https://*|http://localhost*|http://127.0.0.1*) VA_API_URL=${REPLY%/}; set_yaml_api_url "$VA_API_URL"; set_env_value VA_API_URL "$VA_API_URL" ;;
          *) say "the mothership URL must use HTTPS" ;;
        esac ;;
    esac
  done
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
    {
      printf 'header = "Authorization: %s"\nheader = "Accept: application/json"\n' "$VA_API_AUTHORIZATION"
      [ -z "$CA_BUNDLE" ] || printf 'cacert = "%s"\n' "$CA_BUNDLE"
      [ "$PINNED" = "0" ] || printf 'insecure\n'
    } |
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
  prepare_install_dir
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

# Validate an explicit mothership URL before anything is written to disk;
# step 4 persists it to va.yaml and .env, and VA_REGISTER=0 never reaches
# the registration-time check.
[ "$VA_API_URL_EXPLICIT" = "0" ] || validate_api_url

stage_work_dir
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
# No Compose check: the node is one `docker run`. The image carries kamailio,
# FreeSWITCH, the node and its CLI, and stopped shipping a compose scaffold on
# 2026-08-26.

step "2/6  Platform image"
# An archive named up front is always installed, replacing the tag if it is
# already present — that is how a node is upgraded. Only an unspecified source
# lets a present image stand.
if [ -z "$VA_IMAGE_ARCHIVE" ] && docker_cmd image inspect "$VA_VOIP_IMAGE" >/dev/null 2>&1; then
  say "$VA_VOIP_IMAGE is already present"
elif choose_image_source && [ -n "$VA_IMAGE_ARCHIVE" ]; then
  # Offline path: a `docker save` archive (plain or gzip) of the node image.
  # No registry credentials are needed or requested.
  ARCHIVE_FILE=$VA_IMAGE_ARCHIVE
  case "$VA_IMAGE_ARCHIVE" in
    http://*|https://*)
      # Downloaded beside nothing else and removed on exit. A sibling
      # <url>.sha256, when the server has one, must match; without one the
      # download is trusted as-is, exactly like a local file.
      ARCHIVE_DOWNLOAD="$(mktemp /tmp/voipappz-image-archive.XXXXXX)"
      say "downloading $VA_IMAGE_ARCHIVE"
      curl -fL --progress-bar --retry 5 --retry-all-errors -o "$ARCHIVE_DOWNLOAD" "$VA_IMAGE_ARCHIVE" \
        || die "could not download $VA_IMAGE_ARCHIVE"
      if curl -fsSL -o "$ARCHIVE_DOWNLOAD.sha256" "$VA_IMAGE_ARCHIVE.sha256" 2>/dev/null; then
        EXPECTED_SHA="$(tr -d '[:space:]' < "$ARCHIVE_DOWNLOAD.sha256" | cut -c1-64)"
        ACTUAL_SHA="$(sha256sum "$ARCHIVE_DOWNLOAD" | cut -d' ' -f1)"
        [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ] \
          || die "sha256 mismatch for $VA_IMAGE_ARCHIVE (expected $EXPECTED_SHA, got $ACTUAL_SHA)"
        say "sha256 verified"
      else
        say "no .sha256 published beside the archive; skipping checksum"
      fi
      ARCHIVE_FILE=$ARCHIVE_DOWNLOAD ;;
  esac
  say "loading $ARCHIVE_FILE"
  LOADED="$(docker_cmd load -q -i "$ARCHIVE_FILE")" \
    || die "could not load an image from $VA_IMAGE_ARCHIVE"
  case "$ARCHIVE_DOWNLOAD" in
    /tmp/voipappz-image-archive.*) rm -f -- "$ARCHIVE_DOWNLOAD" "$ARCHIVE_DOWNLOAD.sha256" ;;
  esac
  ARCHIVE_DOWNLOAD=""
  if ! docker_cmd image inspect "$VA_VOIP_IMAGE" >/dev/null 2>&1; then
    # The archive was saved under another name (or untagged). Retag the single
    # loaded image so Compose and the CLI helpers find it as $VA_VOIP_IMAGE.
    LOADED_REF="$(printf '%s\n' "$LOADED" |
      sed -n 's/^Loaded image\( ID\)\{0,1\}: //p' | sort -u)"
    NL='
'
    case "$LOADED_REF" in
      '') die "$VA_IMAGE_ARCHIVE did not load $VA_VOIP_IMAGE" ;;
      *"$NL"*)
        die "$VA_IMAGE_ARCHIVE holds several images; set VA_VOIP_IMAGE to the one to use" ;;
    esac
    docker_cmd tag "$LOADED_REF" "$VA_VOIP_IMAGE" \
      || die "could not tag $LOADED_REF as $VA_VOIP_IMAGE"
    say "tagged $LOADED_REF as $VA_VOIP_IMAGE"
  fi
  LOADED=""
  LOADED_REF=""
else
  if [ -z "${VA_REGISTRY_USER:-}" ]; then ask "Docker Hub user"; VA_REGISTRY_USER=$REPLY; fi
  if [ -z "${VA_REGISTRY_TOKEN:-}" ]; then
    ask "Docker Hub token (input hidden)" silent
    VA_REGISTRY_TOKEN=$REPLY
  fi
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

step "3/6  Node image"
# THE IMAGE IS THE WHOLE NODE. It used to carry /stack — a compose scaffold the
# installer copied out — and va-crystal dropped that on 2026-08-26
# (ci/Dockerfile.stack: "NO /stack, NO SIBLING CHECKOUT"). kamailio's config,
# FreeSWITCH's, the s6 tree and the CLI are all inside it now, so there is
# nothing to extract and no compose file to run: one `docker run`, one
# container. The installation directory holds only what belongs to THIS node —
# config/va.yaml, .env and the CA bundle.
fs_cmd mkdir -p "$WORK_DIR/config"
docker_cmd run --rm --entrypoint voipappz "$VA_VOIP_IMAGE" node --help >/dev/null \
  || die "$VA_VOIP_IMAGE has no working node CLI"
say "verified the in-container CLI of $VA_VOIP_IMAGE"

step "4/6  va.yaml"
VA_YAML="$WORK_DIR/config/va.yaml"
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
  say "keeping $INSTALL_DIR/config/va.yaml"
elif has_tty; then
  say "running the existing setup wizard"
  image_cli_tty
  WIZARD_RAN=1
else
  # Unattended and no YAML given: the node-only setup with its defaults (a
  # generated UUID and name, detected addresses). Nothing is asked.
  say "no va.yaml and no terminal; creating one with the node CLI defaults"
  image_cli /work/config/va.yaml setup --ci >/dev/null \
    || die "the node CLI could not create va.yaml; pass VA_CONFIG=/path/to/va.yaml"
fi
[ -f "$VA_YAML" ] || die "setup did not create $VA_YAML"
fs_cmd chmod 0644 "$VA_YAML"

# Optional extra CA bundle (PEM) for a mothership whose TLS chain is not
# trusted by the image. Verification stays enabled; this only adds anchors.
if [ -n "$VA_CA_BUNDLE" ]; then
  [ -r "$VA_CA_BUNDLE" ] || die "no readable CA bundle at $VA_CA_BUNDLE"
  grep -q 'BEGIN CERTIFICATE' "$VA_CA_BUNDLE" || die "$VA_CA_BUNDLE is not a PEM certificate bundle"
  CA_BUNDLE="$WORK_DIR/config/ca-bundle.pem"
  if [ -f "$CA_BUNDLE" ] && cmp -s "$VA_CA_BUNDLE" "$CA_BUNDLE"; then
    say "CA bundle is already current"
  else
    fs_cmd cp "$VA_CA_BUNDLE" "$CA_BUNDLE"
    say "installed $VA_CA_BUNDLE -> $CA_BUNDLE"
  fi
  fs_cmd chmod 0644 "$CA_BUNDLE"
elif [ -f "$WORK_DIR/config/ca-bundle.pem" ]; then
  CA_BUNDLE="$WORK_DIR/config/ca-bundle.pem"
  say "keeping $INSTALL_DIR/config/ca-bundle.pem"
fi
# Whether it starts now or later, a node with a bundle runs with it mounted
# and named by SSL_CERT_FILE — the pin its CLI verifies the mothership against.
[ -z "$CA_BUNDLE" ] || say "the node will trust $INSTALL_DIR/config/ca-bundle.pem"

# The bundle has to reach the RUNNING node too, not just registration: the node
# calls the mothership for dialplan and SBC routing on every call, and without
# these anchors those calls die with "certificate verify failed" mid-INVITE.
# The CA bundle, when there is one, is mounted into the node and named by
# SSL_CERT_FILE at `docker run` (below) — the pin the node CLI verifies the
# mothership against.

# The one thing a node must be told: where its mothership is. Asked only when
# nothing supplied it (no VA_API_URL, no mothership in the YAML) and a terminal
# exists; unattended installs keep the default.
if [ "$VA_API_URL_EXPLICIT" = "0" ] && has_tty && { [ "$WIZARD_RAN" = "1" ] || [ -z "$(yaml_api_url)" ]; }; then
  _url_default="$(yaml_api_url)"; [ -n "$_url_default" ] || _url_default=$VA_API_URL
  while :; do
    ask "Mothership URL [$_url_default]"
    [ -n "$REPLY" ] || REPLY=$_url_default
    case "$REPLY" in
      https://*|http://localhost*|http://127.0.0.1*) VA_API_URL=${REPLY%/}; VA_API_URL_EXPLICIT=1; break ;;
      *) printf '  the mothership URL must use HTTPS\n' > /dev/tty ;;
    esac
  done
fi
if [ "$VA_API_URL_EXPLICIT" = "1" ]; then
  set_yaml_api_url "$VA_API_URL"
  say "using mothership $VA_API_URL"
elif [ -z "$(yaml_api_url)" ]; then
  set_yaml_api_url "$VA_API_URL"
fi
# The broker lives beside the mothership: with no broker in the YAML and no
# VA_NATS_URL, use nats://<mothership host>:4222.
if [ -z "$VA_NATS_URL" ] && [ -z "$(yaml_broker_url)" ]; then
  _api_host=${VA_API_URL#*://}; _api_host=${_api_host%%/*}; _api_host=${_api_host%%:*}
  [ -n "$_api_host" ] && VA_NATS_URL="nats://$_api_host:4222" && say "broker derived from the mothership host: $VA_NATS_URL"
fi
if [ -n "$VA_NATS_URL" ] && [ -z "$(yaml_broker_url)" ]; then
  set_yaml_broker_url "$VA_NATS_URL"
fi
if [ -z "$(yaml_broker_url)" ]; then
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
if [ "$VA_API_URL_EXPLICIT" = "1" ]; then
  [ "$CONFIG_API_URL" = "$VA_API_URL" ] \
    || die "the node CLI did not preserve the requested mothership URL"
else
  [ -z "$CONFIG_API_URL" ] || VA_API_URL=$CONFIG_API_URL
fi
set_env_value VA_API_URL "$VA_API_URL"
# Which image this node runs, recorded for the next run and for an operator
# reading the file.
set_env_value VA_VOIP_IMAGE "$VA_VOIP_IMAGE"

# The CLI writes the bundled app-plane broker into .env (loopback, with a
# token). When va.yaml names a different broker host, that YAML value is the
# node's broker and must reach Compose — both as the URL and as the host the
# voip service maps `nats` to. A same-host CLI value is kept as-is so its
# credentials survive.
BROKER_URL="$(yaml_broker_url)"
if [ -n "$BROKER_URL" ] && \
   [ "$(host_of_url "$BROKER_URL")" != "$(host_of_url "$CONFIG_NATS_URL")" ]; then
  say "using broker $BROKER_URL from va.yaml"
else
  BROKER_URL=$CONFIG_NATS_URL
fi
set_env_value VA_NATS_URL "$BROKER_URL"
BROKER_HOST="$(host_of_url "$BROKER_URL")"
BROKER_IP="${VA_NATS_HOST:-$(resolve_host "$BROKER_HOST")}"
[ -n "$BROKER_IP" ] || [ -z "$BROKER_HOST" ] \
  || die "could not resolve broker host $BROKER_HOST; set VA_NATS_HOST to its IP address"
[ "$BROKER_IP" = "$BROKER_HOST" ] || say "broker $BROKER_HOST resolves to $BROKER_IP"
set_env_value VA_NATS_HOST "$BROKER_IP"

step "5/6  Registration"
SELECTED_CUSTOMER_UUID=""
if [ "$VA_REGISTER" = "1" ]; then
  if [ -z "${VA_API_AUTHORIZATION:-}" ]; then
    set_account_authorization
  fi
  validate_authorization
  VA_API_EMAIL=""
  VA_API_PASSWORD=""
  unset VA_API_EMAIL VA_API_PASSWORD 2>/dev/null
  validate_api_url
  ensure_mothership_reachable
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

commit_install_dir

step "6/6  The node"
if [ "$START" = "1" ]; then
  # THE THREE VALUES THE IMAGE CANNOT DERIVE FROM va.yaml. Everything else the
  # container needs it reads from the mounted YAML itself (the va-env oneshot
  # runs `voipappz env --export --s6` before any service starts). These three
  # are secrets: the CLI generated them into .env at setup and reads them back
  # on a rerun, so a restart never rotates what the node already uses.
  FS_PASSWORD="$(fs_cmd sed -n 's/^VA_FREESWITCH_PASSWORD=//p' "$INSTALL_DIR/.env" | head -1)"
  LIC_JWT="$(fs_cmd sed -n 's/^VA_LICENSE_JWT_SECRET=//p' "$INSTALL_DIR/.env" | head -1)"
  LIC_ENC="$(fs_cmd sed -n 's/^VA_LICENSE_ENCRYPTION_KEY=//p' "$INSTALL_DIR/.env" | head -1)"
  if [ -z "$FS_PASSWORD" ] || [ -z "$LIC_JWT" ] || [ -z "$LIC_ENC" ]; then
    die "$INSTALL_DIR/.env is missing the FreeSWITCH or licence secrets; rerun the installer"
  fi

  # This installer owns the name `va-voip`: replacing it IS how a node is
  # upgraded, and there is no other project to conflict with now that Compose
  # is gone. Subscribers live in a named volume, so they survive the swap.
  if docker_cmd inspect va-voip >/dev/null 2>&1; then
    say "replacing the running node container"
    docker_cmd rm -f va-voip >/dev/null 2>&1 || die "could not remove the existing va-voip container"
  fi

  # --network host: a SIP node advertises its own addresses and takes RTP on a
  # wide port range; a bridge would rewrite neither. The capabilities are what
  # FreeSWITCH needs to set thread priorities and lock memory, and kamailio to
  # manage its own sockets.
  set -- docker_cmd run -d --name va-voip \
    --network host \
    --restart unless-stopped \
    --cap-add NET_ADMIN --cap-add SYS_NICE --cap-add IPC_LOCK \
    --security-opt seccomp=unconfined \
    -v "$INSTALL_DIR/config/va.yaml:/tmp/node.yaml:ro" \
    -v voipappz-kamailio:/var/lib/kamailio \
    -e VA_PATH=/tmp/node.yaml \
    -e "FREESWITCH_PASSWORD=$FS_PASSWORD" \
    -e "VA_FREESWITCH_PASSWORD=$FS_PASSWORD" \
    -e "LICENSE_JWT_SECRET=$LIC_JWT" \
    -e "LICENSE_ENCRYPTION_KEY=$LIC_ENC"
  if [ -n "$CA_BUNDLE" ]; then
    set -- "$@" -v "$INSTALL_DIR/config/ca-bundle.pem:/etc/ssl/va-ca-bundle.pem:ro" \
      -e SSL_CERT_FILE=/etc/ssl/va-ca-bundle.pem
  fi
  "$@" "$VA_VOIP_IMAGE" >/dev/null || die "could not start the node container"
  FS_PASSWORD=""; LIC_JWT=""; LIC_ENC=""
  say "started va-voip from $VA_VOIP_IMAGE"

  _attempt=0
  while [ "$_attempt" -lt 40 ]; do
    curl -fsS --max-time 3 http://127.0.0.1:4000/health >/dev/null 2>&1 && break
    [ "$(docker_cmd inspect -f '{{.State.Running}}' va-voip 2>/dev/null)" = "false" ] \
      && die "va-voip stopped before becoming healthy; run: docker logs va-voip"
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
  if ! docker_cmd exec va-voip voipappz health >/dev/null 2>&1; then
    # Show the verdict itself: which check is down is the whole diagnosis.
    docker_cmd exec va-voip voipappz health 2>&1 | sed 's/^/    /' || true
    die "va-voip did not pass node health (report above); run: docker exec va-voip voipappz health"
  fi
  say "va-voip is healthy"
  say "docker health: $(docker_cmd inspect -f '{{.State.Health.Status}}' va-voip 2>/dev/null || printf 'starting')"
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
  say "start:     rerun this installer, or docker start va-voip once it exists"
fi
say "CLI:       docker exec va-voip voipappz --help"
