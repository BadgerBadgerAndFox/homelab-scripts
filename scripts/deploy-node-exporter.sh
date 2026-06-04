#!/usr/bin/env bash
# deploy-node-exporter.sh — run as root on PVE host
set -uo pipefail
NODE_EXPORTER_PORT=9100
LOG_FILE="/var/log/deploy-node-exporter.log"
DRY_RUN=false
SKIP_IDS=()
ALWAYS_SKIP=(123)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
ok()   { log "${GREEN}[OK]${RESET}  $*"; }
warn() { log "${YELLOW}[WARN]${RESET} $*"; }
err()  { log "${RED}[ERR]${RESET} $*"; }
info() { log "${CYAN}[INFO]${RESET} $*"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; warn "Dry-run mode"; shift ;;
    --skip) IFS=',' read -ra SKIP_IDS <<< "$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--dry-run] [--skip ID1,ID2,...]"; exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done
[[ $EUID -ne 0 ]] && { err "Must run as root"; exit 1; }
command -v pct &>/dev/null || { err "pct not found"; exit 1; }
info "Starting node_exporter deployment — log: $LOG_FILE"
should_skip() {
  local id=$1
  for s in "${ALWAYS_SKIP[@]}" "${SKIP_IDS[@]:-}"; do
    [[ "$s" == "$id" ]] && return 0
  done
  return 1
}
get_pkg_manager() {
  local ctid=$1
  if pct exec "$ctid" -- which apt-get &>/dev/null 2>&1; then echo "apt"
  elif pct exec "$ctid" -- which apk &>/dev/null 2>&1; then echo "apk"
  elif pct exec "$ctid" -- which dnf &>/dev/null 2>&1; then echo "dnf"
  else echo "unknown"; fi
}
get_ip() {
  pct exec "$1" -- bash -c \
    "ip -4 addr show scope global | grep -oP '(?<=inet )[0-9.]+' | head -1" 2>/dev/null || echo "unknown"
}
verify_listening() {
  pct exec "$1" -- bash -c \
    "ss -tlnp 2>/dev/null | grep -q ':${NODE_EXPORTER_PORT}'" 2>/dev/null || return 1
}
is_active() {
  local status
  status=$(pct exec "$1" -- systemctl is-active prometheus-node-exporter 2>/dev/null || true)
  [[ "$status" == "active" ]]
}
install_node_exporter() {
  local ctid=$1 pkg_mgr=$2
  case "$pkg_mgr" in
    apt) pct exec "$ctid" -- bash -c "
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq prometheus-node-exporter
      systemctl enable --now prometheus-node-exporter" ;;
    apk) pct exec "$ctid" -- bash -c "
      apk add --quiet prometheus-node-exporter
      rc-update add prometheus-node-exporter default
      rc-service prometheus-node-exporter start" ;;
    dnf) pct exec "$ctid" -- bash -c "
      dnf install -y -q golang-github-prometheus-node-exporter
      systemctl enable --now prometheus-node-exporter" ;;
  esac
}
RUNNING_IDS=()
while read -r id; do RUNNING_IDS+=("$id"); done < <(pct list | awk 'NR>1 && $2=="running" {print $1}')
PASS=0; FAIL=0; SKIP=0; ALREADY=0
printf "${BOLD}%-6s %-22s %-10s %-8s %s${RESET}\n" "CTID" "NAME" "PKG_MGR" "STATUS" "IP"
printf '%s\n' "────────────────────────────────────────────────────────────────"
for ctid in "${RUNNING_IDS[@]}"; do
  name=$(pct config "$ctid" 2>/dev/null | awk '/^hostname:/{print $2}') || name=""
  [[ -z "$name" ]] && name="ct-${ctid}"
  if should_skip "$ctid"; then
    printf "%-6s %-22s %-10s ${YELLOW}%-8s${RESET} -\n" "$ctid" "$name" "-" "SKIPPED"
    ((SKIP++)); continue
  fi
  if is_active "$ctid"; then
    ip=$(get_ip "$ctid")
    printf "%-6s %-22s %-10s ${GREEN}%-8s${RESET} %s\n" "$ctid" "$name" "-" "EXISTS" "${ip}:${NODE_EXPORTER_PORT}"
    ((ALREADY++)); continue
  fi
  pkg_mgr=$(get_pkg_manager "$ctid")
  if [[ "$pkg_mgr" == "unknown" ]]; then
    printf "%-6s %-22s ${RED}FAIL${RESET} no pkg manager\n" "$ctid" "$name"
    ((FAIL++)); continue
  fi
  if $DRY_RUN; then
    printf "%-6s %-22s %-10s ${CYAN}DRY-RUN${RESET}\n" "$ctid" "$name" "$pkg_mgr"
    continue
  fi
  info "Installing CT $ctid ($name) via $pkg_mgr..."
  if install_node_exporter "$ctid" "$pkg_mgr" >> "$LOG_FILE" 2>&1; then
    ip=$(get_ip "$ctid")
    if verify_listening "$ctid"; then
      printf "%-6s %-22s %-10s ${GREEN}OK${RESET} %s\n" "$ctid" "$name" "$pkg_mgr" "${ip}:${NODE_EXPORTER_PORT}"
      ok "CT $ctid: ${ip}:${NODE_EXPORTER_PORT}"; ((PASS++))
    else
      printf "%-6s %-22s %-10s ${YELLOW}NO-PORT${RESET}\n" "$ctid" "$name" "$pkg_mgr"
      warn "CT $ctid ($name): installed but port not listening"; ((PASS++))
    fi
  else
    printf "%-6s %-22s ${RED}FAIL${RESET}\n" "$ctid" "$name"
    err "CT $ctid ($name): install failed"; ((FAIL++))
  fi
done
echo ""
printf '%s\n' "────────────────────────────────────────────────────────────────"
printf "${BOLD}Summary:${RESET} ${GREEN}%d installed${RESET} | ${CYAN}%d existing${RESET} | ${YELLOW}%d skipped${RESET} | ${RED}%d failed${RESET}\n" \
  "$PASS" "$ALREADY" "$SKIP" "$FAIL"
echo ""
if ! $DRY_RUN && [[ $((PASS + ALREADY)) -gt 0 ]]; then
  info "Prometheus scrape_configs targets:"
  echo "  - job_name: 'node'"
  echo "    static_configs:"
  echo "      - targets:"
  for ctid in "${RUNNING_IDS[@]}"; do
    should_skip "$ctid" && continue
    name=$(pct config "$ctid" 2>/dev/null | awk '/^hostname:/{print $2}') || true
    ip=$(get_ip "$ctid")
    [[ -n "$ip" && "$ip" != "unknown" ]] && \
      printf "          - '%s:%s'  # %s CT%s\n" "$ip" "$NODE_EXPORTER_PORT" "$name" "$ctid"
  done
fi
info "Done. Log: $LOG_FILE"
