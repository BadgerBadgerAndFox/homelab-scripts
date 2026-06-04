#!/usr/bin/env bash
# =============================================================================
# nvidia-update-pve.sh
# NVIDIA Driver Auto-Update for Proxmox VE 9.x
#
# - Installs/upgrades the NVIDIA driver on the PVE host with DKMS support
# - Handles Secure Boot: generates a MOK key if absent, configures DKMS
#   auto-signing via /etc/dkms/framework.conf.d/
# - Discovers all LXC containers that share the GPU (via lxc.mount.entry
#   nvidia references in /etc/pve/lxc/*.conf)
# - Pushes the same driver .run file into each impacted LXC and installs
#   it with --no-kernel-modules (userspace only, as required for LXC)
#
# Usage:
#   chmod +x nvidia-update-pve.sh
#   ./nvidia-update-pve.sh [OPTIONS]
#
# Options:
#   -v VERSION   NVIDIA driver version  (e.g. 580.95.05)
#   -u URL       Full download URL for the .run file
#                (auto-constructed from -v if omitted)
#   -f FILE      Use a pre-downloaded local .run file
#   -y           Non-interactive: accept all prompts automatically
#   -n           Dry-run: show what would happen, make no changes
#   -h           Show this help
#
# Secure Boot notes:
#   If Secure Boot is enabled the script will:
#     1. Generate an RSA-2048 MOK key + self-signed certificate under
#        /root/module-signing/ (skipped if already present).
#     2. Enroll the certificate with mokutil. On next reboot you MUST
#        complete enrollment in the MOK Manager UEFI screen.
#     3. Configure DKMS to sign every built module automatically.
#   If Secure Boot is disabled these steps are skipped.
#
# Requirements:
#   - Must run as root on the PVE host
#   - PVE 9.x (Debian 13 / trixie base)
#   - Internet access or a pre-downloaded .run file (-f)
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD} $*${NC}"; \
            echo -e "${BOLD}══════════════════════════════════════════${NC}"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
DRIVER_VERSION=""
DRIVER_URL=""
LOCAL_RUN_FILE=""
AUTO_YES=false
DRY_RUN=false
MOK_DIR="/root/module-signing"
MOK_KEY="${MOK_DIR}/module-signing.key"
MOK_CERT="${MOK_DIR}/module-signing.der"
DKMS_SIGNING_CONF="/etc/dkms/framework.conf.d/nvidia-signing.conf"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    sed -n '/^# Usage:/,/^# =/{ /^# =/d; s/^# \{0,3\}//; p }' "$0"
    exit 0
}

while getopts ":v:u:f:ynh" opt; do
    case $opt in
        v) DRIVER_VERSION="$OPTARG" ;;
        u) DRIVER_URL="$OPTARG" ;;
        f) LOCAL_RUN_FILE="$OPTARG" ;;
        y) AUTO_YES=true ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        :) die "Option -$OPTARG requires an argument." ;;
        \?) die "Unknown option: -$OPTARG" ;;
    esac
done

# ── Guard: must be root ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root."

# ── Guard: must be on a PVE host ──────────────────────────────────────────────
command -v pveversion &>/dev/null || die "pveversion not found. This script must run on a Proxmox VE host."
command -v pct        &>/dev/null || die "pct not found. Is pve-container installed?"

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$@"
    fi
}

# ── Prompt helper ─────────────────────────────────────────────────────────────
confirm() {
    # $1 = prompt text; returns 0 (yes) or 1 (no)
    if $AUTO_YES; then return 0; fi
    local ans
    read -r -p "$1 [y/N] " ans
    [[ ${ans,,} == y* ]]
}

# =============================================================================
# SECTION 1 — Resolve the driver .run file
# =============================================================================
section "Resolving NVIDIA driver source"

if [[ -n "$LOCAL_RUN_FILE" ]]; then
    [[ -f "$LOCAL_RUN_FILE" ]] || die "Local file not found: $LOCAL_RUN_FILE"
    RUN_FILE="$LOCAL_RUN_FILE"
    # Extract version from filename if not supplied
    if [[ -z "$DRIVER_VERSION" ]]; then
        DRIVER_VERSION=$(basename "$RUN_FILE" | grep -oP '\d+\.\d+\.\d+' | head -1)
        [[ -n "$DRIVER_VERSION" ]] || die "Cannot parse version from filename. Use -v to supply it."
    fi
    info "Using local file: $RUN_FILE  (version $DRIVER_VERSION)"
else
    [[ -n "$DRIVER_VERSION" ]] || die "Provide -v VERSION or -f FILE. Run with -h for help."
    RUN_FILE="/root/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

    if [[ -z "$DRIVER_URL" ]]; then
        DRIVER_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
    fi

    if [[ -f "$RUN_FILE" ]]; then
        info "Driver already downloaded: $RUN_FILE"
    else
        info "Downloading NVIDIA driver ${DRIVER_VERSION}..."
        run curl -# -L -o "$RUN_FILE" "$DRIVER_URL"
        ok "Download complete."
    fi
fi

run chmod +x "$RUN_FILE"

# =============================================================================
# SECTION 2 — Install host prerequisites (PVE 9.x)
# =============================================================================
section "Installing host prerequisites (PVE 9.x)"

CURRENT_KERNEL=$(uname -r)
info "Running kernel: ${CURRENT_KERNEL}"

# Verify kernel headers match running kernel — the most common failure point
HEADERS_PKG="proxmox-headers-${CURRENT_KERNEL}"
if dpkg -s "$HEADERS_PKG" &>/dev/null; then
    ok "Kernel headers matched: ${HEADERS_PKG}"
else
    warn "Kernel headers package '${HEADERS_PKG}' not installed. Installing now..."
    run apt-get update -qq
    run apt-get install -y "$HEADERS_PKG"
fi

# Core build packages (proxmox-default-headers tracks future kernels automatically)
PKGS=(build-essential dkms gcc g++ make proxmox-default-headers "$HEADERS_PKG")
MISSING_PKGS=()
for pkg in "${PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    info "Installing missing packages: ${MISSING_PKGS[*]}"
    run apt-get update -qq
    run apt-get install -y "${MISSING_PKGS[@]}"
else
    ok "All prerequisite packages present."
fi

# =============================================================================
# SECTION 3 — Secure Boot / MOK handling
# =============================================================================
section "Secure Boot detection and MOK key management"

SB_ENABLED=false
if command -v mokutil &>/dev/null; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null || true)
    if echo "$SB_STATE" | grep -qi "SecureBoot enabled"; then
        SB_ENABLED=true
        warn "Secure Boot is ENABLED — module signing is required."
    else
        info "Secure Boot is disabled — skipping MOK steps."
    fi
else
    info "mokutil not found — assuming Secure Boot is not active."
fi

if $SB_ENABLED; then
    # ── 3a. Generate MOK key if not already present ───────────────────────────
    if [[ -f "$MOK_KEY" && -f "$MOK_CERT" ]]; then
        ok "MOK key/cert already exist at ${MOK_DIR} — skipping generation."
    else
        info "Generating MOK RSA-2048 key and self-signed certificate..."
        run mkdir -p "$MOK_DIR"
        run chmod 700 "$MOK_DIR"
        run openssl req -new -x509 \
            -newkey rsa:2048 \
            -keyout "$MOK_KEY" \
            -outform DER \
            -out "$MOK_CERT" \
            -nodes -days 36500 \
            -subj "/CN=NVIDIA DKMS MOK - PVE $(hostname)"
        ok "MOK key generated."
    fi

    # ── 3b. Enroll key in UEFI if not already enrolled ───────────────────────
    ALREADY_ENROLLED=false
    if [[ -f "$MOK_CERT" ]]; then
        if { mokutil --test-key "$MOK_CERT" 2>/dev/null || true; } | grep -q "already enrolled"; then
            ALREADY_ENROLLED=true
            ok "MOK certificate already enrolled."
        fi
    fi

    if ! $ALREADY_ENROLLED; then
        warn "The MOK certificate is NOT yet enrolled in UEFI firmware."
        echo ""
        echo "  mokutil will queue the certificate for enrollment."
        echo "  After this script completes you MUST reboot and complete"
        echo "  enrollment in the MOK Manager screen:"
        echo "    1. Select 'Enroll MOK'"
        echo "    2. Select 'Continue' → 'Yes'"
        echo "    3. Enter the password you will type below"
        echo "    4. Select 'OK' — system will reboot again"
        echo ""
        if confirm "Enroll the MOK certificate now?"; then
            run mokutil --import "$MOK_CERT"
            warn "MOK enrollment queued. You MUST complete it on next reboot before the driver will load."
        else
            warn "MOK enrollment skipped. The driver may fail to load with Secure Boot enabled."
        fi
    fi

    # ── 3c. Configure DKMS auto-signing ──────────────────────────────────────
    info "Configuring DKMS to auto-sign modules with MOK key..."
    run mkdir -p "$(dirname "$DKMS_SIGNING_CONF")"

    if ! $DRY_RUN; then
        cat > "$DKMS_SIGNING_CONF" <<EOF
# Auto-generated by nvidia-update-pve.sh
# DKMS will sign every built module using this MOK key.
# Key and cert must match what is enrolled in UEFI via mokutil.
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
EOF
    else
        echo "[DRY-RUN] Would write DKMS signing config to ${DKMS_SIGNING_CONF}"
    fi
    ok "DKMS signing config written: ${DKMS_SIGNING_CONF}"
fi

# =============================================================================
# SECTION 4 — Blacklist nouveau
# =============================================================================
section "Blacklisting nouveau driver"

NOUVEAU_CONF="/etc/modprobe.d/blacklist-nouveau.conf"
if [[ -f "$NOUVEAU_CONF" ]]; then
    ok "nouveau already blacklisted."
else
    info "Writing nouveau blacklist..."
    if ! $DRY_RUN; then
        cat > "$NOUVEAU_CONF" <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        update-initramfs -u -k all
    else
        echo "[DRY-RUN] Would write ${NOUVEAU_CONF} and run update-initramfs"
    fi
    ok "nouveau blacklisted."
fi

# =============================================================================
# SECTION 5 — Remove old NVIDIA driver (if present)
# =============================================================================
section "Removing existing NVIDIA driver"

OLD_VER=$(dkms status 2>/dev/null | awk -F'[/,]' '/^nvidia/ { print $2 }' | head -1 | tr -d ' ')

if [[ -n "$OLD_VER" ]]; then
    if [[ "$OLD_VER" == "$DRIVER_VERSION" ]]; then
        info "DKMS already shows nvidia/${DRIVER_VERSION}."
        if confirm "Force reinstall anyway?"; then
            run dkms remove -m nvidia -v "$OLD_VER" --all || true
        else
            info "Skipping reinstall — driver already at target version."
            OLD_VER=""  # signal: skip install below
        fi
    else
        info "Removing old DKMS entry: nvidia/${OLD_VER}"
        run dkms remove -m nvidia -v "$OLD_VER" --all || true
    fi
fi

# Remove any APT-installed nvidia packages (won't exist in a .run install,
# but safe to attempt)
if dpkg -l 2>/dev/null | grep -qE '^ii.*nvidia'; then
    info "Removing APT nvidia packages..."
    run apt-get purge -y --auto-remove 'nvidia-*' || true
fi

# =============================================================================
# SECTION 6 — Install NVIDIA driver on PVE host
# =============================================================================
section "Installing NVIDIA driver ${DRIVER_VERSION} on PVE host"

GPU_LXCS_STOPPED=()

if [[ -z "$OLD_VER" ]] && dkms status 2>/dev/null | grep -q "nvidia/${DRIVER_VERSION}"; then
    ok "Driver ${DRIVER_VERSION} already installed and registered with DKMS."
else
    # Stop GPU-sharing LXCs then unload modules
    # nvidia_uvm refcount stays >0 while any container holds GPU fds open
    info "Scanning for running GPU-sharing LXC containers..."
    
    for conf in /etc/pve/lxc/*.conf; do
        grep -q "nvidia\|/dev/dri" "$conf" 2>/dev/null || continue
        ctid=$(basename "$conf" .conf)
        pct status "$ctid" 2>/dev/null | grep -q running && GPU_LXCS_STOPPED+=("$ctid")
    done
    if [[ ${#GPU_LXCS_STOPPED[@]} -gt 0 ]]; then
        info "Stopping GPU LXCs: ${GPU_LXCS_STOPPED[*]}"
        for ctid in "${GPU_LXCS_STOPPED[@]}"; do
            run pct stop "$ctid"
        done
        $DRY_RUN || sleep 5
    else
        info "No running GPU-sharing LXCs found."
    fi
    info "Stopping nvidia-persistenced..."
    systemctl stop nvidia-persistenced 2>/dev/null || true
    $DRY_RUN || sleep 1
    NVIDIA_LSMOD=(nvidia_uvm nvidia_drm nvidia_modeset nvidia)
    NVIDIA_RMMOD=(nvidia-uvm nvidia-drm nvidia-modeset nvidia)
    info "Unloading NVIDIA kernel modules..."
    for i in "${!NVIDIA_LSMOD[@]}"; do
        lmod="${NVIDIA_LSMOD[$i]}"
        rmod="${NVIDIA_RMMOD[$i]}"
        if lsmod | grep -q "^${lmod} "; then
            info "Unloading ${lmod}..."
            if ! $DRY_RUN; then
                if ! rmmod "$rmod" 2>/dev/null; then
                    RC=$(lsmod | grep "${lmod} " | cut -d" " -f3)
                    error "Cannot unload ${lmod} (refcount=${RC}) - check lsof /dev/nvidia*"
                    error "Re-run after stopping all GPU workloads."
                    exit 1
                fi
                ok "Unloaded ${lmod}."
            fi
        fi
    done
    ok "All NVIDIA modules unloaded."

    info "Running installer (this may take several minutes)..."


    # Installer flags for headless / PVE use:
    #   --dkms           register with DKMS for auto-rebuild on kernel updates
    #   --no-opengl-files  PVE host is headless
    #   --no-x-check     don't abort if X is somehow detected
    #   --silent         suppress ncurses UI (answers driven by --ui-* flags below)
    # Secure Boot: pass MOK key to installer for module signing.
    # --silent skips signing unless keys are supplied explicitly.
    SB_ARGS=()
    if [[ -f "$MOK_KEY" && -f "$MOK_CERT" ]] && mokutil --sb-state 2>/dev/null | grep -q "enabled"; then
        info "Secure Boot active — signing modules with MOK key."
        openssl x509 -inform DER -in "$MOK_CERT" -out /tmp/nv-mok.pem 2>/dev/null
        SB_ARGS+=(--module-signing-secret-key "$MOK_KEY")
        SB_ARGS+=(--module-signing-public-key /tmp/nv-mok.pem)
    fi
    run "$RUN_FILE" \
        --dkms \
        --no-opengl-files \
        --no-x-check \
        --silent \
        --kernel-module-type=open \
        "${SB_ARGS[@]}"
    rm -f /tmp/nv-mok.pem

    ok "NVIDIA driver ${DRIVER_VERSION} installed on host."
fi

# ── Post-install verification ─────────────────────────────────────────────────
section "Verifying host driver installation"

info "DKMS status:"
if ! $DRY_RUN; then
    dkms status | grep nvidia || warn "No nvidia entry in dkms status."
fi

info "Testing nvidia-smi (GPU must be present)..."
if ! $DRY_RUN; then
    if nvidia-smi &>/dev/null; then
        ok "nvidia-smi succeeded."
        nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null \
            | while IFS=',' read -r name ver; do
                info "  GPU: ${name} | Driver: ${ver}"
              done
    else
        warn "nvidia-smi failed. If Secure Boot MOK enrollment is pending, reboot and re-run."
    fi
fi

if $SB_ENABLED && ! $DRY_RUN; then
    info "Verifying module signing:"
    modinfo nvidia 2>/dev/null | grep -i signer || warn "Could not verify module signer."
fi

# =============================================================================
# SECTION 7 — Discover LXC containers that share the GPU
# =============================================================================
section "Discovering GPU-sharing LXC containers"

mapfile -t GPU_LXC_IDS < <(
    grep -l "nvidia" /etc/pve/lxc/*.conf 2>/dev/null \
    | sed 's|.*/\([0-9]*\)\.conf|\1|' \
    | sort -n
)

if [[ ${#GPU_LXC_IDS[@]} -eq 0 ]]; then
    info "No LXC containers found with NVIDIA mount entries."
    info "To add GPU passthrough to a container add these lines to /etc/pve/lxc/<CTID>.conf:"
    echo ""
    echo "  lxc.cgroup2.devices.allow: c 195:* rwm"
    echo "  lxc.cgroup2.devices.allow: c 510:* rwm"
    echo "  lxc.cgroup2.devices.allow: c 235:* rwm"
    echo "  lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file"
    echo "  lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file"
    echo "  lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file"
    echo ""
    exit 0
fi

info "Found ${#GPU_LXC_IDS[@]} GPU-sharing container(s): ${GPU_LXC_IDS[*]}"

# Confirm before touching containers
if ! confirm "Update NVIDIA driver in all ${#GPU_LXC_IDS[@]} container(s)?"; then
    info "Container update skipped."
    exit 0
fi

# =============================================================================
# SECTION 8 — Update driver inside each LXC container
# =============================================================================
section "Updating NVIDIA driver in each LXC container"

# Track containers that were stopped by us so we can return them to that state
declare -A WAS_STOPPED=()

update_container() {
    local CTID="$1"
    local CT_NAME
    CT_NAME=$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}') || CT_NAME="ct${CTID}"
    echo ""
    info "── Container ${CTID} (${CT_NAME}) ──────────────────────────────"
    local STOPPED_BY_US=false
    for s in "${GPU_LXCS_STOPPED[@]:-}"; do
        [[ "$s" == "$CTID" ]] && STOPPED_BY_US=true && break
    done
    local CT_STATUS
    CT_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
    if [[ "$CT_STATUS" != "running" ]]; then
        warn "Container ${CTID} is stopped — starting..."
        $STOPPED_BY_US || WAS_STOPPED[$CTID]=1
        if ! $DRY_RUN; then
            if ! pct start "$CTID" 2>/tmp/pct_err; then
                error "Cannot start ${CTID}: $(cat /tmp/pct_err)"
                error "Check device passthrough config (missing devices etc) and re-run."
                FAILED_CONTAINERS+=("$CTID"); return 1
            fi
            local waited=0
            until pct status "$CTID" 2>/dev/null | grep -q running; do
                sleep 2; waited=$((waited+2))
                [[ $waited -ge 30 ]] && { error "Container ${CTID} timed out starting."; FAILED_CONTAINERS+=("$CTID"); return 1; }
            done
            sleep 2
        fi
    fi
    local CURRENT_CT_VER=""
    if ! $DRY_RUN; then
        CURRENT_CT_VER=$(pct exec "$CTID" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]') || true
    fi
    if [[ "$CURRENT_CT_VER" == "$DRIVER_VERSION" ]]; then
        ok "Container ${CTID}: already at ${DRIVER_VERSION} — skipping."; return 0
    fi
    [[ -n "$CURRENT_CT_VER" ]] && info "Container ${CTID}: current=${CURRENT_CT_VER:-unknown} target=${DRIVER_VERSION}"
    local CT_RUN_PATH="/root/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
    local CT_SCRIPT="/root/nv-install-$$.sh"
    info "Pushing driver to container ${CTID}..."
    run pct push "$CTID" "$RUN_FILE" "$CT_RUN_PATH"
    if ! $DRY_RUN; then
        printf '#!/bin/sh\nset -e\nchmod +x "%s"\n"%s" --no-kernel-modules --no-opengl-files --silent --no-x-check\nrm -f "%s"\n' "$CT_RUN_PATH" "$CT_RUN_PATH" "$CT_RUN_PATH" > /tmp/nv_ct_$$.sh
        pct push "$CTID" /tmp/nv_ct_$$.sh "$CT_SCRIPT"
        rm -f /tmp/nv_ct_$$.sh
        pct exec "$CTID" -- sh "$CT_SCRIPT"
        pct exec "$CTID" -- rm -f "$CT_SCRIPT"
    else
        echo "[DRY-RUN] would install driver in container ${CTID}"
    fi
    if ! $DRY_RUN; then
        local NEW_CT_VER
        NEW_CT_VER=$(pct exec "$CTID" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]') || true
        if [[ "$NEW_CT_VER" == "$DRIVER_VERSION" ]]; then
            ok "Container ${CTID}: updated to ${NEW_CT_VER}."
        else
            warn "Container ${CTID}: nvidia-smi reports '${NEW_CT_VER}' — verify manually."
        fi
    else
        ok "Container ${CTID}: [DRY-RUN] complete."
    fi
}



FAILED_CONTAINERS=()

for CTID in "${GPU_LXC_IDS[@]}"; do
    if update_container "$CTID"; then
        true
    else
        error "Container ${CTID}: update FAILED."
        FAILED_CONTAINERS+=("$CTID")
    fi
done

# ── Restore containers that were stopped before we started ───────────────────
section "Restoring container states"
if [[ ${#GPU_LXCS_STOPPED[@]} -gt 0 ]]; then
    info "Restarting GPU LXCs: ${GPU_LXCS_STOPPED[*]}"
    for ctid in "${GPU_LXCS_STOPPED[@]}"; do
        pct status "$ctid" 2>/dev/null | grep -q running && { ok "Container $ctid already running."; continue; }; run pct start "$ctid" || warn "Could not restart $ctid"
    done
fi
for CTID in "${!WAS_STOPPED[@]}"; do
    info "Stopping container ${CTID} (it was stopped before we began)..."
    run pct stop "$CTID" || warn "Could not stop container ${CTID} — check manually."
done

# =============================================================================
# SECTION 9 — Summary
# =============================================================================
section "Update Summary"

ok  "Host driver:       ${DRIVER_VERSION}"
info "Secure Boot:      $(if $SB_ENABLED; then echo 'ENABLED (MOK managed)'; else echo 'disabled'; fi)"
info "Containers found: ${#GPU_LXC_IDS[@]}"

if [[ ${#FAILED_CONTAINERS[@]} -gt 0 ]]; then
    error "Failed containers: ${FAILED_CONTAINERS[*]}"
    echo ""
    echo "  For each failed container, manually run:"
    for CTID in "${FAILED_CONTAINERS[@]}"; do
        echo "    pct push ${CTID} ${RUN_FILE} /root/$(basename "$RUN_FILE")"
        echo "    pct exec ${CTID} -- /root/$(basename "$RUN_FILE") --no-kernel-modules --silent"
    done
else
    ok "All containers updated successfully."
fi

_MOK_PENDING=false
if $SB_ENABLED && [[ -f "$MOK_CERT" ]]; then
    { mokutil --test-key "$MOK_CERT" 2>/dev/null || true; } | grep -q "already enrolled" || _MOK_PENDING=true
fi
if $_MOK_PENDING; then
    echo ""
    warn "╔══════════════════════════════════════════════════════════╗"
    warn "║  REBOOT REQUIRED — MOK enrollment pending                ║"
    warn "║  Complete the MOK Manager steps at next boot to          ║"
    warn "║  allow the signed driver to load with Secure Boot on.    ║"
    warn "╚══════════════════════════════════════════════════════════╝"
fi

echo ""
ok "Done."
