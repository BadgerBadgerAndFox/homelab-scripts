#!/usr/bin/env bash
# restart-bifrost.sh — gracefully restart Bifrost on CT 124 and wait for recovery
# Run as root on PVE host. Handles the ssh-mcp session drop automatically.

set -uo pipefail

DOCKER_LXC=124
BIFROST_URL="http://192.168.1.95:8080"
MAX_WAIT=120
INTERVAL=3

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${RED}[ERR ]${RESET} $*"; }

info "Restarting Bifrost container..."
pct exec $DOCKER_LXC -- docker restart bifrost
echo -n "Waiting for Bifrost to become healthy"

elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
  sleep $INTERVAL
  elapsed=$((elapsed + INTERVAL))
  # Check health via HTTP (doesn't need ssh-mcp session)
  status=$(curl -s --max-time 3 "$BIFROST_URL" -o /dev/null -w '%{http_code}' 2>/dev/null)
  if [ "$status" = "200" ]; then
    echo ""
    ok "Bifrost is up (${elapsed}s)"
    break
  fi
  echo -n "."
done

if [ $elapsed -ge $MAX_WAIT ]; then
  echo ""
  err "Bifrost did not recover within ${MAX_WAIT}s"
  exit 1
fi

# Verify ssh-mcp reconnected by testing a simple exec
info "Verifying SSH-MCP session..."
sleep 5
test_result=$(pct exec $DOCKER_LXC -- docker exec ssh-mcp sh -c 'echo ok' 2>/dev/null || echo "failed")
if [ "$test_result" = "ok" ]; then
  ok "SSH-MCP session active"
else
  warn "SSH-MCP may need manual reconnect via Arcane UI"
fi

ok "Done. Bifrost is healthy."
