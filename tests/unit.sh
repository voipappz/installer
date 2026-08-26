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
WORK_DIR="$TMP"; INSTALL_DIR="$TMP"; mkdir -p "$TMP/config"
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

printf '\n'
if ((fails == 0)); then printf '\033[1munit: all green\033[0m\n'; else printf '\033[1m!! %d unit failure(s)\033[0m\n' "$fails"; exit 1; fi
