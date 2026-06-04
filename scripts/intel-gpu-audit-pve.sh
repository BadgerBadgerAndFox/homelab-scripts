#!/usr/bin/env bash
# =============================================================================
# intel-gpu-audit-pve.sh
# Intel iGPU LXC Audit & Repair for Proxmox VE 9.x
#
# Audits Intel iGPU passthrough configuration across LXC containers.
# PVE 9.x uses native dev: entries in container config (not lxc.mount.entry).
#
# HOST CHECKS
#   1. i915/xe kernel module loaded
#   2. /dev/dri device nodes exist with correct permissions
#   3. render/video group GIDs on host
#
# CONTAINER CHECKS (per container with dev: /dev/dri/* entries)
#   4. dev: entries reference devices that actually exist on host
#   5. dev: entries have correct gid= mapping (render=993, video=44)
#   6. /dev/dri devices visible inside running container
#   7. render group GID inside container matches host
#   8. Intel userspace packages present (intel-media-va-driver etc)
#   9. vainfo smoke-test (VA-API functional)
#
# Usage:
#   ./intel-gpu-audit-pve.sh [OPTIONS]
#
# Options:
#   -r        Auto-remediate all issues
#   -y        Non-interactive
#   -n        Dry-run: report only, no changes
#   -p PKGS   Extra packages (comma-separated, default: intel-media-va-driver,vainfo)
#   -s        Skip package checks
#   -h        Show help
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
issue()   { echo -e "${RED}[ISSUE]${NC} $*"; ISSUES+=("$*"); }
fixed()   { echo -e "${GREEN}[FIXED]${NC} $*"; FIXES+=("$*"); }
skipped() { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
section() {
    echo -e "\n${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BOLD} $*${NC}"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
}

AUTO_REMEDIATE=false
AUTO_YES=false
DRY_RUN=false
SKIP_PACKAGES=false
EXTRA_PACKAGES="intel-media-va-driver,vainfo"
ISSUES=()
FIXES=()
declare -A WAS_STOPPED=()
CONF_BACKUP_DIR="/root/pve-lxc-conf-backup-$(date +%Y%m%d-%H%M%S)"

usage() { sed -n '/^# Usage:/,/^# =/{ /^# =/d; s/^# \{0,3\}//; p }' "$0"; exit 0; }

while getopts ":rysnp:h" opt; do
    case $opt in
        r) AUTO_REMEDIATE=true; AUTO_YES=true ;;
        y) AUTO_YES=true ;;
        n) DRY_RUN=true ;;
        s) SKIP_PACKAGES=true ;;
        p) EXTRA_PACKAGES="$OPTARG" ;;
        h) usage ;;
        :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { error "Must run as root."; exit 1; }
command -v pct &>/dev/null        || { error "pct not found."; exit 1; }
command -v pveversion &>/dev/null || { error "Not a PVE host."; exit 1; }

run() {
    if $DRY_RUN; then echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else eval "$@"; fi
}

confirm() {
    if $AUTO_YES; then return 0; fi
    local ans; read -r -p "$1 [y/N] " ans; [[ ${ans,,} == y* ]]
}

ensure_running() {
    local CTID="$1"
    local status
    status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        info "Starting container ${CTID} temporarily..."
        WAS_STOPPED[$CTID]=1
        run pct start "$CTID"
        $DRY_RUN || sleep 4
    fi
}

restore_states() {
    for CTID in "${!WAS_STOPPED[@]}"; do
        info "Stopping container ${CTID} (was stopped before audit)..."
        run pct stop "$CTID" || warn "Could not stop ${CTID}."
    done
}

backup_conf() {
    local CTID="$1" CONF="/etc/pve/lxc/${1}.conf"
    $DRY_RUN && return
    mkdir -p "$CONF_BACKUP_DIR"
    [[ ! -f "${CONF_BACKUP_DIR}/${CTID}.conf.bak" ]] && \
        cp "$CONF" "${CONF_BACKUP_DIR}/${CTID}.conf.bak" && \
        info "Backed up ${CONF}"
}

# =============================================================================
# SECTION 1 — Host kernel module
# =============================================================================
section "Host: Intel GPU kernel module"

GPU_MODULE=""
# Capture lsmod once — avoids pipefail triggering on grep exit 1 (no match)
_LSMOD=$(lsmod 2>/dev/null || true)
if echo "$_LSMOD" | grep -qE "^xe[[:space:]]"; then
    GPU_MODULE="xe"
    ok "Intel xe module loaded (Arc / Meteor Lake+)."
fi
if echo "$_LSMOD" | grep -qE "^i915[[:space:]]"; then
    [[ -n "$GPU_MODULE" ]] && GPU_MODULE="i915+xe" || GPU_MODULE="i915"
    ok "Intel i915 module loaded."
fi
unset _LSMOD

if [[ -z "$GPU_MODULE" ]]; then
    issue "Neither i915 nor xe kernel module is loaded."
    warn "Try: modprobe i915  (or xe for newer hardware)"
else
    # || true prevents pipefail aborting on grep finding nothing
    if { dmesg 2>/dev/null || true; } | grep -qiE "guc.*failed|huc.*failed|firmware.*failed.*(i915|xe)"; then
        issue "GPU firmware load failure in dmesg — check: dmesg | grep -iE 'i915|xe' | grep -i fail"
    else
        ok "No GPU firmware errors in dmesg."
    fi
fi

# =============================================================================
# SECTION 2 — Host /dev/dri nodes
# =============================================================================
section "Host: /dev/dri device nodes"

[[ -d /dev/dri ]] || { error "/dev/dri does not exist."; exit 1; }

mapfile -t RENDER_NODES < <(ls /dev/dri/renderD* 2>/dev/null || true)
mapfile -t CARD_NODES   < <(ls /dev/dri/card*   2>/dev/null || true)

[[ ${#RENDER_NODES[@]} -gt 0 ]] && ok "Render nodes: ${RENDER_NODES[*]}" \
    || issue "No /dev/dri/renderD* nodes found."
[[ ${#CARD_NODES[@]}   -gt 0 ]] && ok "Card nodes:   ${CARD_NODES[*]}" \
    || warn "No /dev/dri/card* nodes found."

# Get render and video GIDs from host
HOST_RENDER_GID=$(getent group render 2>/dev/null | cut -d: -f3 || echo "")
HOST_VIDEO_GID=$(getent group video   2>/dev/null | cut -d: -f3 || echo "")

[[ -n "$HOST_RENDER_GID" ]] && ok "Host render GID : ${HOST_RENDER_GID}" \
    || { issue "render group missing on host"; run groupadd -r render; HOST_RENDER_GID=$(getent group render | cut -d: -f3); }
[[ -n "$HOST_VIDEO_GID" ]]  && ok "Host video GID  : ${HOST_VIDEO_GID}" \
    || warn "video group missing on host."

# =============================================================================
# SECTION 3 — Discover GPU-sharing containers (PVE 9 dev: syntax)
# =============================================================================
section "Discovering GPU-sharing LXC containers"

# PVE 9 uses native dev: entries — find containers with /dev/dri device entries
mapfile -t GPU_LXC_IDS < <(
    grep -rl "dev[0-9]*:.*dev/dri\|dev[0-9]*:.*nvidia" /etc/pve/lxc/*.conf 2>/dev/null \
    | sed 's|.*/\([0-9]*\)\.conf|\1|' | sort -n
)

if [[ ${#GPU_LXC_IDS[@]} -eq 0 ]]; then
    info "No containers found with GPU dev: entries."
    echo ""
    echo "  PVE 9 GPU passthrough uses native dev: syntax. Example:"
    echo "  Add via: pct set <CTID> --dev0 /dev/dri/renderD128,gid=${HOST_RENDER_GID:-993}"
    echo "           pct set <CTID> --dev1 /dev/dri/card0,gid=${HOST_VIDEO_GID:-44}"
    echo ""
    exit 0
fi

info "Found ${#GPU_LXC_IDS[@]} GPU-sharing container(s): ${GPU_LXC_IDS[*]}"

# =============================================================================
# SECTION 4 — Per-container audit
# =============================================================================
section "Per-container audit"

IFS=',' read -ra USERSPACE_PKGS <<< "$EXTRA_PACKAGES"

audit_container() {
    local CTID="$1"
    local CONF="/etc/pve/lxc/${CTID}.conf"
    local CT_NAME
    CT_NAME=$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}') \
        || CT_NAME="ct${CTID}"
    local CT_ISSUES=0

    echo ""
    info "── Container ${CTID} (${CT_NAME}) ──────────────────────────────"

    # ── 4a. Audit dev: entries for /dev/dri devices ───────────────────────────
    # PVE 9 dev: format: devN: /dev/path,gid=NNN[,uid=NNN][,mode=OCTAL]
    local DRI_DEV_ISSUES=false

    while IFS= read -r line; do
        # Extract device path and gid
        local devpath gid_val
        devpath=$(echo "$line" | grep -oP '(?<=:\s)/[^,]+' || true)
        gid_val=$(echo "$line"  | grep -oP 'gid=\K[0-9]+' || true)

        [[ -z "$devpath" ]] && continue
        echo "$devpath" | grep -q "/dev/dri/" || continue

        # Check device exists on host
        if [[ ! -c "$devpath" ]]; then
            issue "Container ${CTID}: dev entry references non-existent host device: ${devpath}"
            CT_ISSUES=$((CT_ISSUES+1))
            DRI_DEV_ISSUES=true
            continue
        fi

        # Check GID is correct
        local expected_gid=""
        case "$devpath" in
            */renderD*) expected_gid="$HOST_RENDER_GID" ;;
            */card*)    expected_gid="$HOST_VIDEO_GID" ;;
        esac

        if [[ -n "$expected_gid" && -n "$gid_val" && "$gid_val" != "$expected_gid" ]]; then
            issue "Container ${CTID}: ${devpath} has gid=${gid_val}, expected ${expected_gid}"
            CT_ISSUES=$((CT_ISSUES+1))
            DRI_DEV_ISSUES=true
        fi

        ok "  dev: ${devpath} gid=${gid_val:-unset} — host device exists."

    done < <(grep -E "^dev[0-9]+:.*dev/dri/" "$CONF" || true)

    # Remediate dev: GID issues via pct set
    if $DRI_DEV_ISSUES; then
        if $AUTO_REMEDIATE || confirm "  Fix dev: GID entries for container ${CTID}?"; then
            # Find highest existing dev index
            local max_idx=-1
            while IFS= read -r dline; do
                local idx
                idx=$(echo "$dline" | grep -oP '^dev\K[0-9]+')
                [[ $idx -gt $max_idx ]] && max_idx=$idx
            done < <(grep -E "^dev[0-9]+:" "$CONF" || true)

            # Re-set all /dev/dri entries with correct GIDs
            while IFS= read -r dline; do
                local didx devpath
                didx=$(echo "$dline" | grep -oP '^dev\K[0-9]+')
                devpath=$(echo "$dline" | grep -oP '(?<=:\s)/[^,]+')
                [[ -z "$devpath" ]] && continue
                echo "$devpath" | grep -q "/dev/dri/" || continue

                local correct_gid=""
                case "$devpath" in
                    */renderD*) correct_gid="$HOST_RENDER_GID" ;;
                    */card*)    correct_gid="$HOST_VIDEO_GID" ;;
                esac
                [[ -z "$correct_gid" ]] && continue

                backup_conf "$CTID"
                run pct set "$CTID" --dev${didx} "${devpath},gid=${correct_gid}"
                fixed "Container ${CTID}: dev${didx} set to ${devpath},gid=${correct_gid}"
            done < <(grep -E "^dev[0-9]+:.*dev/dri/" "$CONF" || true)
        else
            skipped "Container ${CTID}: dev: GID fix skipped."
        fi
    else
        ok "Container ${CTID}: all /dev/dri dev: entries correct."
    fi

    # ── 4b. Runtime checks (need running container) ───────────────────────────
    local CT_STATUS
    CT_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
    local DO_RUNTIME=false

    if [[ "$CT_STATUS" == "running" ]]; then
        DO_RUNTIME=true
    elif $AUTO_REMEDIATE || confirm "  Start container ${CTID} for runtime checks?"; then
        ensure_running "$CTID"
        DO_RUNTIME=true
    else
        info "Container ${CTID}: skipping runtime checks (stopped)."
    fi

    $DO_RUNTIME || return 0

    # ── 4c. /dev/dri visible inside container ─────────────────────────────────
    local CT_HAS_RENDER="no"
    if ! $DRY_RUN; then
        CT_HAS_RENDER=$(pct exec "$CTID" -- \
            sh -c "test -c /dev/dri/renderD128 && echo yes || echo no" 2>/dev/null) || CT_HAS_RENDER="no"
    fi

    if [[ "$CT_HAS_RENDER" != "yes" ]]; then
        issue "Container ${CTID}: /dev/dri/renderD128 not visible inside container."
        CT_ISSUES=$((CT_ISSUES+1))
        warn "  Container may need restart to pick up current dev: config."
        if $AUTO_REMEDIATE || confirm "  Restart container ${CTID}?"; then
            run pct reboot "$CTID"
            $DRY_RUN || sleep 5
            CT_HAS_RENDER=$(pct exec "$CTID" -- \
                sh -c "test -c /dev/dri/renderD128 && echo yes || echo no" 2>/dev/null) || CT_HAS_RENDER="no"
            [[ "$CT_HAS_RENDER" == "yes" ]] && fixed "Container ${CTID}: /dev/dri/renderD128 now visible." \
                || issue "Container ${CTID}: /dev/dri/renderD128 still not visible after restart."
        fi
    else
        ok "Container ${CTID}: /dev/dri/renderD128 visible inside container."
    fi

    # ── 4d. render GID inside container ──────────────────────────────────────
    if ! $DRY_RUN; then
        local CT_RENDER_GID=""
        CT_RENDER_GID=$(pct exec "$CTID" -- \
            sh -c "getent group render 2>/dev/null | cut -d: -f3 || true" \
            2>/dev/null | tr -d '[:space:]') || true

        if [[ -z "$CT_RENDER_GID" ]]; then
            issue "Container ${CTID}: render group missing inside container."
            CT_ISSUES=$((CT_ISSUES+1))
            if $AUTO_REMEDIATE || confirm "  Create render group in container ${CTID}?"; then
                run pct exec "$CTID" -- groupadd -r -g "$HOST_RENDER_GID" render
                fixed "Container ${CTID}: render group created (GID ${HOST_RENDER_GID})."
            fi
        elif [[ "$CT_RENDER_GID" != "$HOST_RENDER_GID" ]]; then
            issue "Container ${CTID}: render GID mismatch — container=${CT_RENDER_GID}, host=${HOST_RENDER_GID}."
            CT_ISSUES=$((CT_ISSUES+1))
            if $AUTO_REMEDIATE || confirm "  Fix render GID in container ${CTID}?"; then
                if ! $DRY_RUN; then
                    COLLIDING=$(pct exec "$CTID" -- getent group "$HOST_RENDER_GID" 2>/dev/null | cut -d: -f1 || true)
                    if [[ -n "$COLLIDING" && "$COLLIDING" != "render" ]]; then
                        warn "Container ${CTID}: GID ${HOST_RENDER_GID} taken by ${COLLIDING} - relocating."
                        FREE_GID=$(pct exec "$CTID" -- sh -c "cut -d: -f3 /etc/group | sort -n | grep -v ^$ | tail -1")
                        FREE_GID=$((FREE_GID + 1))
                        pct exec "$CTID" -- groupmod -g "$FREE_GID" "$COLLIDING" && info "Moved ${COLLIDING} to ${FREE_GID}." || error "Could not relocate ${COLLIDING}."
                    fi
                    if pct exec "$CTID" -- groupmod -g "$HOST_RENDER_GID" render 2>/dev/null; then
                        fixed "Container ${CTID}: render GID corrected to ${HOST_RENDER_GID}."
                    else
                        error "Container ${CTID}: groupmod failed - fix manually."
                        CT_ISSUES=$((CT_ISSUES+1))
                    fi
                else
                    echo "[DRY-RUN] would fix render GID in container ${CTID}"
                fi
            fi
        else
            ok "Container ${CTID}: render GID matches host (${HOST_RENDER_GID})."
        fi
    fi

    # ── 4e. Userspace package sync ────────────────────────────────────────────
    if ! $SKIP_PACKAGES && ! $DRY_RUN; then
        info "Container ${CTID}: checking Intel userspace packages..."

        local PKG_MGR=""
        pct exec "$CTID" -- sh -c "command -v apt-get" &>/dev/null && PKG_MGR="apt"
        pct exec "$CTID" -- sh -c "command -v dnf"     &>/dev/null && PKG_MGR="dnf"
        pct exec "$CTID" -- sh -c "command -v pacman"  &>/dev/null && PKG_MGR="pacman"

        if [[ -z "$PKG_MGR" ]]; then
            warn "Container ${CTID}: cannot detect package manager — skipping."
        else
            local MISSING_PKGS=()
            for pkg in "${USERSPACE_PKGS[@]}"; do
                local installed="0"
                case $PKG_MGR in
                    apt) installed=$(pct exec "$CTID" -- \
                             sh -c "dpkg -s '${pkg}' 2>/dev/null | grep -c 'Status: install ok installed' || true" \
                             2>/dev/null | tr -d '[:space:]') || installed="0" ;;
                    dnf) installed=$(pct exec "$CTID" -- \
                             sh -c "rpm -q '${pkg}' &>/dev/null && echo 1 || echo 0" \
                             2>/dev/null | tr -d '[:space:]') || installed="0" ;;
                    pacman) installed=$(pct exec "$CTID" -- \
                             sh -c "pacman -Q '${pkg}' &>/dev/null && echo 1 || echo 0" \
                             2>/dev/null | tr -d '[:space:]') || installed="0" ;;
                esac
                [[ "$installed" != "1" ]] && MISSING_PKGS+=("$pkg")
            done

            if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
                issue "Container ${CTID}: missing packages: ${MISSING_PKGS[*]}"
                CT_ISSUES=$((CT_ISSUES+1))
                if $AUTO_REMEDIATE || confirm "  Install missing packages in container ${CTID}?"; then
                    case $PKG_MGR in
                        apt)
                            printf '#!/bin/sh
apt-get update -qq && apt-get install -y %s
' "${MISSING_PKGS[*]}" > /tmp/igapkg_$$.sh
                            pct push "$CTID" /tmp/igapkg_$$.sh /tmp/igapkg.sh
                            rm -f /tmp/igapkg_$$.sh
                            run pct exec "$CTID" -- sh /tmp/igapkg.sh
                            pct exec "$CTID" -- rm -f /tmp/igapkg.sh
                            ;;
                        dnf)    run pct exec "$CTID" -- dnf install -y "${MISSING_PKGS[@]}" ;;
                        pacman) run pct exec "$CTID" -- pacman -Sy --noconfirm "${MISSING_PKGS[@]}" ;;
                    esac
                    fixed "Container ${CTID}: installed ${MISSING_PKGS[*]}."
                fi
            else
                ok "Container ${CTID}: all Intel userspace packages present."
            fi
        fi
    fi

    # ── 4f. vainfo smoke test ─────────────────────────────────────────────────
    if ! $DRY_RUN && pct exec "$CTID" -- sh -c "command -v vainfo" &>/dev/null 2>&1; then
        local VAINFO_OUT=""
        # Run with DRM backend to avoid X server requirement on headless containers
        VAINFO_OUT=$(pct exec "$CTID" -- \
            sh -c "LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128 2>&1 \
                   || LIBVA_DRIVER_NAME=i965 vainfo --display drm --device /dev/dri/renderD128 2>&1 \
                   || true" 2>/dev/null) || VAINFO_OUT=""

        if echo "$VAINFO_OUT" | grep -q "VAProfileH264\|VAProfileHEVC\|VAProfileAV1\|VAProfileVP9"; then
            local PROFILE_COUNT
            PROFILE_COUNT=$(echo "$VAINFO_OUT" | grep -c "VAProfile" || true)
            ok "Container ${CTID}: VA-API functional — ${PROFILE_COUNT} decode profiles."
        elif echo "$VAINFO_OUT" | grep -qi "error\|failed\|cannot open"; then
            # Only flag as issue if it's not just the X server warning
            local REAL_ERRORS
            REAL_ERRORS=$(echo "$VAINFO_OUT" | grep -iv "x server\|x display\|cannot connect to X" \
                | grep -i "error\|failed\|cannot open" || true)
            if [[ -n "$REAL_ERRORS" ]]; then
                issue "Container ${CTID}: vainfo errors: $(echo "$REAL_ERRORS" | head -2)"
                CT_ISSUES=$((CT_ISSUES+1))
            else
                ok "Container ${CTID}: VA-API driver loaded (X server not available, expected on headless)."
            fi
        else
            warn "Container ${CTID}: vainfo output inconclusive — check manually."
        fi
    fi

    [[ $CT_ISSUES -eq 0 ]] && ok "Container ${CTID}: all checks passed."
}

FAILED_CONTAINERS=()
for CTID in "${GPU_LXC_IDS[@]}"; do
    audit_container "$CTID" || FAILED_CONTAINERS+=("$CTID")
done

# =============================================================================
# SECTION 5 — Restore container states
# =============================================================================
if [[ ${#WAS_STOPPED[@]} -gt 0 ]]; then
    section "Restoring container states"
    for CTID in "${!WAS_STOPPED[@]}"; do
        info "Stopping container ${CTID}..."
        run pct stop "$CTID" || warn "Could not stop ${CTID}."
    done
fi

# =============================================================================
# SECTION 6 — Summary
# =============================================================================
section "Audit Summary"

PVE_VER=$(pveversion 2>/dev/null | head -1 || echo "unknown")
info "PVE version       : ${PVE_VER}"
info "Kernel            : $(uname -r)"
info "GPU module        : ${GPU_MODULE:-not loaded}"
info "Containers audited: ${#GPU_LXC_IDS[@]}"
echo ""

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    ok "No issues found — all containers healthy."
else
    warn "${#ISSUES[@]} issue(s) found:"
    for i in "${ISSUES[@]}"; do echo -e "  ${RED}•${NC} ${i}"; done
fi

if [[ ${#FIXES[@]} -gt 0 ]]; then
    echo ""
    ok "${#FIXES[@]} fix(es) applied:"
    for f in "${FIXES[@]}"; do echo -e "  ${GREEN}•${NC} ${f}"; done
    echo ""
    warn "Config backups written to: ${CONF_BACKUP_DIR}"
fi

[[ ${#ISSUES[@]} -gt 0 && ${#FIXES[@]} -lt ${#ISSUES[@]} ]] && \
    warn "Some issues not remediated — re-run with -r to fix automatically."

echo ""
ok "Done."
