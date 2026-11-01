#!/bin/sh
# make mcp — how to connect an LLM (Claude Code, any MCP client) to this node.
#
# The node runs its CLI's MCP server in the background: the s6 service
# va-mcp, `voipappz mcp http`, plain HTTP on 127.0.0.1:4010 unless
# VA_MCP_HOST/VA_MCP_PORT say otherwise. A request needs the bearer token and
# must come from an address in VA_MCP_ALLOW_FROM (loopback when unset).
#
# THE TOKEN'S HASH LIVES IN .env (2026-11-01), with the other secrets: the
# node's va.yaml is mounted read-only, so the CLI inside cannot keep it there.
# `make mcp TOKEN=new` mints a token here, keeps only its SHA-256 in .env as
# VA_MCP_TOKEN_SHA256, prints the token once, and `make up` hands it to the
# node. This never prints the token again, nor its hash.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

load_env_file

if [ "${TOKEN:-}" = new ]; then
  _token=$(od -An -tx1 -N32 /dev/urandom | tr -d " \n")
  _hash=$(printf "%s" "$_token" | sha256sum | cut -d" " -f1)
  set_env_value VA_MCP_TOKEN_SHA256 "$_hash"
  VA_MCP_TOKEN_SHA256=$_hash
  printf "\n%sthe MCP token — shown once; keep it in your MCP client%s\n" "$C_BOLD" "$C_OFF" > /dev/tty
  printf "%s\n" "$_token" > /dev/tty
  say "its SHA-256 is in $VA_ENV_FILE as VA_MCP_TOKEN_SHA256; run make up to give it to the node"
  _token=""; _hash=""
fi

require_docker
require_running

# The node's own values: the s6 environment the service runs with, then va.yaml.
node_env() {
  docker exec "$NODE" sh -c "cat /run/s6/container_environment/$1 2>/dev/null || true"
}
mcp_host=$(node_env VA_MCP_HOST); mcp_host=${mcp_host:-127.0.0.1}
mcp_port=$(node_env VA_MCP_PORT); mcp_port=${mcp_port:-4010}
allow=$(node_env VA_MCP_ALLOW_FROM)
# Configured (in .env) and applied (in the running node) can differ until make up.
_applied=$(node_env VA_MCP_TOKEN_SHA256)
if [ -n "${VA_MCP_TOKEN_SHA256:-}" ] && [ "$_applied" = "$VA_MCP_TOKEN_SHA256" ]; then
  token="set"
elif [ -n "${VA_MCP_TOKEN_SHA256:-}" ]; then
  token="in $VA_ENV_FILE, not yet in the node — run: make up"
elif [ -n "$_applied" ]; then
  token="set in the node, but not in $VA_ENV_FILE — the next make up drops it"
else
  token="unset"
fi
_applied=""
if docker exec "$NODE" sh -c '/command/s6-svstat /run/service/va-mcp 2>/dev/null' | grep -q '^up'; then
  service="up"
else
  service="down"
fi

printf '\n%sMCP on %s%s\n' "$C_BOLD" "$NODE" "$C_OFF"
say "service    va-mcp $service (voipappz mcp http)"
say "listens    http://$mcp_host:$mcp_port/mcp"
say "token      $token$( [ "$token" = unset ] && printf ' — mint one: make mcp TOKEN=new')"
say "clients    ${allow:-loopback only (VA_MCP_ALLOW_FROM unset)}"
case "$mcp_host" in
  127.*|localhost|::1) say "reach      this host only; for another machine set VA_MCP_HOST=0.0.0.0 and VA_MCP_ALLOW_FROM in config/va.yaml env:, then make up" ;;
esac

# The address other machines reach: the source of the default route, not
# whichever interface hostname -I lists first (often a docker bridge).
host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
url_host=$mcp_host
case "$mcp_host" in 0.0.0.0) url_host=${host_ip:-<this-host>} ;; esac

printf '\n%s.mcp.json — over HTTP (the background server; operator actions allowed)%s\n' "$C_BOLD" "$C_OFF"
cat <<JSON
{
  "mcpServers": {
    "voipappz-$NODE": {
      "type": "http",
      "url": "http://$url_host:$mcp_port/mcp",
      "headers": { "Authorization": "Bearer \${VOIPAPPZ_MCP_TOKEN}" }
    }
  }
}
JSON
say "export VOIPAPPZ_MCP_TOKEN in the client's environment; the token is never written here"

printf '\n%s.mcp.json — over stdio (no port, no token; read-only unless VA_MCP_ALLOW_WRITE=1)%s\n' "$C_BOLD" "$C_OFF"
cat <<JSON
{
  "mcpServers": {
    "voipappz-$NODE-stdio": {
      "command": "ssh",
      "args": ["-T", "$(id -un)@${host_ip:-<this-host>}", "docker", "exec", "-i", "$NODE", "voipappz", "mcp"]
    }
  }
}
JSON
say "on this host itself: \"command\": \"docker\", \"args\": [\"exec\", \"-i\", \"$NODE\", \"voipappz\", \"mcp\"]"
