#!/bin/sh
# make mcp — how to connect an LLM (Claude Code, any MCP client) to this node.
#
# The node runs its CLI's MCP server in the background: the s6 service
# va-mcp, `voipappz mcp http`, plain HTTP on 127.0.0.1:4010 unless
# VA_MCP_HOST/VA_MCP_PORT say otherwise. A request needs the bearer token
# (`make cli ARGS="mcp token"` prints it once; the node keeps only its hash)
# and must come from an address in VA_MCP_ALLOW_FROM (loopback when unset).
# This prints the state of that server and the client entry to paste. It
# never prints the token or its hash.
set -eu
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_docker
require_running

# The node's own values: the s6 environment the service runs with, then va.yaml.
node_env() {
  docker exec "$NODE" sh -c "cat /run/s6/container_environment/$1 2>/dev/null || true"
}
mcp_host=$(node_env VA_MCP_HOST); mcp_host=${mcp_host:-127.0.0.1}
mcp_port=$(node_env VA_MCP_PORT); mcp_port=${mcp_port:-4010}
allow=$(node_env VA_MCP_ALLOW_FROM)
if [ -n "$(node_env VA_MCP_TOKEN_SHA256)" ] ||
   docker exec "$NODE" sh -c 'grep -q "VA_MCP_TOKEN_SHA256" "${VA_PATH:-/opt/va.yaml}" 2>/dev/null'; then
  token="set"
else
  token="unset"
fi
if docker exec "$NODE" sh -c 's6-svstat /run/service/va-mcp 2>/dev/null' | grep -q '^up'; then
  service="up"
else
  service="down"
fi

printf '\n%sMCP on %s%s\n' "$C_BOLD" "$NODE" "$C_OFF"
say "service    va-mcp $service (voipappz mcp http)"
say "listens    http://$mcp_host:$mcp_port/mcp"
say "token      $token$( [ "$token" = unset ] && printf ' — mint one: make cli ARGS="mcp token"')"
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
