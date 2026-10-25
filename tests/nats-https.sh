#!/usr/bin/env bash
# Real node runtime -> Kong HTTPS /nats -> authenticated NATS + JetStream.
# The external network has no broker: TCP fallback cannot pass this test.
# Run with MOTHERSHIP_DIR=/path/to/mothership; CI downloads its real config.
set -Eeuo pipefail
NODE_IMAGE=${VA_VOIP_IMAGE:-ghcr.io/voipappz/node:latest}
NATS_IMAGE=${NATS_IMAGE:-nats:alpine}
BOX_IMAGE=${NATS_BOX_IMAGE:-natsio/nats-box:latest}
RUN_DIR=$(mktemp -d)
ID="installer-nats-https-$$"
NODE_UUID=11111111-1111-4111-8111-111111111111
SUBJECT="node:$NODE_UUID:node.health"
cleanup() {
  docker rm -f "$ID-node" "$ID-bad" "$ID-probe" "$ID-kong" "$ID-nats" >/dev/null 2>&1 || true
  docker network rm "$ID-edge" "$ID-back" >/dev/null 2>&1 || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
for command in docker openssl curl jq; do command -v "$command" >/dev/null || fail "$command is required"; done

if [ -z "${MOTHERSHIP_DIR:-}" ]; then
  : "${MOTHERSHIP_TOKEN:?MOTHERSHIP_TOKEN must read the private mothership repository}"
  # No token in argv, URL, logs, or the archive. Same archive boundary as the
  # installer integration test; never build a fake copy of the edge config.
  printf 'header = "Authorization: Bearer %s"\n' "$MOTHERSHIP_TOKEN" |
    curl --config - --fail --silent --show-error --location \
      "https://api.github.com/repos/voipappz/mothership/tarball/${MOTHERSHIP_REF:-main}" -o "$RUN_DIR/mothership.tar.gz"
  mkdir "$RUN_DIR/mothership"
  tar -xzf "$RUN_DIR/mothership.tar.gz" --strip-components=1 -C "$RUN_DIR/mothership"
  MOTHERSHIP_DIR="$RUN_DIR/mothership"
fi
unset MOTHERSHIP_TOKEN
KONG_IMAGE=$(sed -n 's/^    image: \(kong:[^ ]*\)$/\1/p' "$MOTHERSHIP_DIR/docker-compose.yaml" | head -1)
[ -n "$KONG_IMAGE" ] || fail 'no Kong image in the mothership compose file'
for image in "$NODE_IMAGE" "$NATS_IMAGE" "$KONG_IMAGE" "$BOX_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
  docker image inspect "$image" --format '{{.Id}}'
done
# Use the real configuration contract, including private native/monitor ports.
sh "$MOTHERSHIP_DIR/scripts/check-kong-contract.sh"
# Satisfy the unrelated ACME requirement: Compose interpolation order varies.
if VA_DOMAIN=nats-ci.invalid VA_NATS_TOKEN='' docker compose --env-file /dev/null -f "$MOTHERSHIP_DIR/docker-compose.yaml" config --quiet > "$RUN_DIR/empty-key.log" 2>&1; then
  fail 'Compose accepted an empty NATS key'
fi
grep -q 'VA_NATS_TOKEN must be set and nonempty' "$RUN_DIR/empty-key.log" || fail 'Compose did not reject the empty key for the expected reason'
pass 'Compose refuses an empty NATS key'

docker network create "$ID-back" >/dev/null
docker network create "$ID-edge" >/dev/null
mkdir "$RUN_DIR/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=installer-ci-ca \
  -keyout "$RUN_DIR/certs/ca.key" -out "$RUN_DIR/certs/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=kong \
  -keyout "$RUN_DIR/certs/server.key" -out "$RUN_DIR/certs/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:kong\n' > "$RUN_DIR/certs/san.ext"
openssl x509 -req -in "$RUN_DIR/certs/server.csr" -CA "$RUN_DIR/certs/ca.pem" \
  -CAkey "$RUN_DIR/certs/ca.key" -CAcreateserial -days 1 -extfile "$RUN_DIR/certs/san.ext" \
  -out "$RUN_DIR/certs/server.pem" 2>/dev/null
chmod 644 "$RUN_DIR/certs/server.pem" "$RUN_DIR/certs/ca.pem"
KEY=$(openssl rand -hex 32)
[ "${GITHUB_ACTIONS:-}" != true ] || echo "::add-mask::$KEY"
# NATS parses the env substitution as config syntax, hence the literal quotes.
export VA_NATS_TOKEN="\"$KEY\""
docker create --name "$ID-nats" --network "$ID-back" --network-alias nats \
  -e VA_NATS_TOKEN "$NATS_IMAGE" -c /nats.conf >/dev/null
docker cp "$MOTHERSHIP_DIR/config/nats/nats.conf" "$ID-nats:/nats.conf"
docker start "$ID-nats" >/dev/null
docker create --name "$ID-kong" --network "$ID-back" --user root \
  -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/kong.yml \
  -e KONG_PROXY_LISTEN='0.0.0.0:8000,0.0.0.0:8443 ssl' \
  -e KONG_SSL_CERT=/certs/server.pem -e KONG_SSL_CERT_KEY=/certs/server.key \
  -e KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=resty.http,cjson.safe "$KONG_IMAGE" >/dev/null
docker network connect --alias kong "$ID-edge" "$ID-kong"
docker cp "$MOTHERSHIP_DIR/config/kong/kong.yaml" "$ID-kong:/kong.yml"
docker cp "$RUN_DIR/certs" "$ID-kong:/certs"
docker start "$ID-kong" >/dev/null
for _ in $(seq 60); do docker exec "$ID-kong" kong health >/dev/null 2>&1 && break; sleep 1; done
docker exec "$ID-kong" kong health >/dev/null || fail 'Kong did not start'
export NATS_URL="nats://default:$KEY@nats:4222"
internal() { docker run --rm --network "$ID-back" -e NATS_URL "$BOX_IMAGE" nats "$@"; }
internal account info >/dev/null
pass 'internal authenticated NATS and JetStream are available'

# Only run the published node process: SIP/media availability is covered by
# the existing full install job. A real NATS health request crosses the edge
# twice; a socket handshake or HTTP 200 alone cannot satisfy this assertion.
printf 'nodes: []\nsip_interfaces: []\n' > "$RUN_DIR/node.yaml"
export SECRET_KEY=$KEY LICENSE_JWT_SECRET=$KEY LICENSE_ENCRYPTION_KEY=$KEY FREESWITCH_PASSWORD=$KEY
start_node() {
  local name=$1 url=$2 cert=${3:-/ca.pem} network=${4:-$ID-edge}
  (umask 077; printf 'NATS_URL=%s\n' "$url" > "$RUN_DIR/node.env")
  docker create --name "$name" --network "$network" --entrypoint /opt/node/node \
    --env-file "$RUN_DIR/node.env" -e SECRET_KEY -e LICENSE_JWT_SECRET -e LICENSE_ENCRYPTION_KEY \
    -e FREESWITCH_PASSWORD -e SSL_CERT_FILE="$cert" -e VA_PATH=/node.yaml \
    -e NODE_UUID="$NODE_UUID" -e API_URL=https://kong:8443 -e FREESWITCH_HOST=127.0.0.1 \
    -e FREESWITCH_PORT=8021 -e VA_INFLUXDB_HOST=127.0.0.1 -e PORT=4000 "$NODE_IMAGE" >/dev/null
  docker cp "$RUN_DIR/node.yaml" "$name:/node.yaml"
  docker cp "$RUN_DIR/certs/ca.pem" "$name:/ca.pem"
  docker start "$name" >/dev/null
}
connected() {
  docker exec "$ID-node" curl -fsS --max-time 3 http://127.0.0.1:4000/metrics 2>/dev/null |
    grep -q '^va_node_nats_connected 1'
}
wait_connected() {
  for _ in $(seq 90); do connected && return; sleep 1; done
  fail 'node did not authenticate to the broker'
}
roundtrip() {
  internal request "$SUBJECT" '{}' --timeout 20s --raw > "$RUN_DIR/reply.json"
  jq -e --arg uuid "$NODE_UUID" '.node_uuid == $uuid and .metrics.nats_connected == 1' "$RUN_DIR/reply.json" >/dev/null || fail 'node health reply was not from the connected node'
}
start_node "$ID-node" "https://default:$KEY@kong:8443/nats"
wait_connected
roundtrip
pass 'real node authenticates and replies over HTTPS /nats with a trusted certificate'
# The real node creates its shared-state KV bucket through this same link.
internal kv info LIVE >/dev/null
pass 'node JetStream KV initialization succeeds over HTTPS'

status=$(docker exec "$ID-node" curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://kong:8000/nats)
case "$status" in 308|426) pass 'plaintext HTTP cannot upgrade to NATS' ;; *) fail "plaintext route returned $status" ;; esac
if docker exec "$ID-node" getent hosts nats >/dev/null 2>&1; then fail 'node can resolve the private broker'; fi
pass 'external node has no direct broker network or TCP fallback'
status=$(docker exec "$ID-node" curl -sS --cacert /ca.pem --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Origin: https://unrelated.example' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' https://kong:8443/nats)
[ "$status" = 403 ] || fail "cross-origin WebSocket upgrade returned $status"
pass 'unrelated browser Origin rejected'


docker restart -t 1 "$ID-nats" >/dev/null
sleep 3
wait_connected
roundtrip
pass 'node reconnects and replies after a broker restart'
docker logs "$ID-node" > "$RUN_DIR/node.log" 2>&1
! grep -Fq "$KEY" "$RUN_DIR/node.log" || fail 'node logs exposed the NATS key'
pass 'node logs redact the NATS key'
docker rm -f "$ID-node" >/dev/null
start_node "$ID-node" "nats://default:$KEY@nats:4222" /ca.pem "$ID-back"
wait_connected
roundtrip
pass 'explicit internal TCP broker still works for the real node'
docker rm -f "$ID-node" >/dev/null

rejected() {
  local label=$1 url=$2 pattern=$3 cert=${4:-/ca.pem}
  start_node "$ID-bad" "$url" "$cert"
  local found=0
  for _ in $(seq 40); do
    docker logs "$ID-bad" > "$RUN_DIR/rejected.log" 2>&1
    if grep -Eq "$pattern" "$RUN_DIR/rejected.log"; then found=1; break; fi
    sleep 1
  done
  [ "$found" = 1 ] || fail "$label: expected rejection was not observed"
  ! grep -q 'NATS: Connected to' "$RUN_DIR/rejected.log" || fail "$label: node connected"
  ! grep -Fq "$KEY" "$RUN_DIR/rejected.log" || fail 'node logs exposed the NATS key'
  docker rm -f "$ID-bad" >/dev/null
  pass "$label"
}
rejected 'wrong NATS key rejected' 'https://default:wrong@kong:8443/nats' 'Authorization|Authentication'
rejected 'missing NATS key rejected' 'https://kong:8443/nats' 'Authorization|Authentication'
rejected 'untrusted TLS certificate rejected' "https://default:$KEY@kong:8443/nats" 'certificate verify failed' /etc/ssl/certs/ca-certificates.crt
IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$ID-edge\").IPAddress}}" "$ID-kong")
rejected 'wrong TLS hostname rejected' "https://default:$KEY@$IP:8443/nats" 'certificate verify failed|hostname mismatch'
pass 'node HTTPS /nats integration and security checks passed'
