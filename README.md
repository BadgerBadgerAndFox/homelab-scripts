# homelab-scripts

Scripts, exporters and dashboards for the retiarius.co.nz homelab (Proxmox VE + UniFi).

## Structure

```
scripts/
  deploy-node-exporter.sh   # Deploy prometheus-node-exporter to all LXCs via pct exec
  nvidia-update-pve.sh      # Install/upgrade NVIDIA driver on PVE host + all GPU LXCs
  intel-gpu-audit-pve.sh    # Audit and repair Intel iGPU passthrough across LXCs
exporters/
  unifi_exporter.py         # Prometheus exporter for UniFi via native API key (no agent)
dashboards/
  unifi-network.json        # Grafana dashboard — UniFi network overview
  gpu-metrics.json          # Grafana dashboard — NVIDIA + Intel GPU per host
  gen_unifi_dash.py         # Generator script for unifi-network.json
```

## Quick start on PVE

```bash
git clone https://github.com/BadgerBadgerAndFox/homelab-scripts.git /opt/homelab-scripts

# Deploy node_exporter to all running LXCs
bash /opt/homelab-scripts/scripts/deploy-node-exporter.sh --dry-run
bash /opt/homelab-scripts/scripts/deploy-node-exporter.sh

# Update
cd /opt/homelab-scripts && git pull
```

---
# Script Documentation

## scripts/deploy-node-exporter.sh

Deploys `prometheus-node-exporter` to every running LXC container on a Proxmox VE host using `pct exec`. Designed to be run once after standing up new LXCs or as part of initial monitoring setup.

### Requirements

- Run as `root` on the PVE host
- `pct` must be in PATH (standard on any PVE host)
- LXCs must be running and have a supported package manager (`apt`, `apk`, or `dnf`)

### Usage

```bash
# Dry run — shows what would happen, no changes made
deploy-node-exporter.sh --dry-run

# Deploy to all running LXCs
deploy-node-exporter.sh

# Skip specific containers (e.g. containers without internet access)
deploy-node-exporter.sh --skip 104,106,110
```

### What it does

1. Iterates all running LXCs via `pct list`
2. Skips CT 123 permanently (reserved — no rootfs)
3. Detects the package manager inside each LXC
4. Installs and enables `prometheus-node-exporter` via the native package manager
5. Verifies the exporter is listening on `:9100`
6. Outputs a ready-to-paste `prometheus.yml` scrape_configs block with all LXC IPs at the end

### Log file

`/var/log/deploy-node-exporter.log`

---

## scripts/nvidia-update-pve.sh

Installs or upgrades the NVIDIA driver on a Proxmox VE 9.x host, then propagates the same driver into all LXC containers that share the GPU via passthrough. Handles Secure Boot MOK key enrollment automatically.

### Requirements

- Run as `root` on the PVE host
- PVE 9.x (Debian 13 / trixie base)
- Internet access **or** a pre-downloaded `.run` file
- `dkms`, `build-essential`, `linux-headers` installed

### Usage

```bash
# Install a specific driver version (downloads automatically)
nvidia-update-pve.sh -v 580.95.05

# Use a pre-downloaded .run file
nvidia-update-pve.sh -f /tmp/NVIDIA-Linux-x86_64-580.95.05.run

# Provide a custom download URL
nvidia-update-pve.sh -u https://example.com/NVIDIA-Linux-x86_64-580.95.05.run

# Non-interactive (no prompts)
nvidia-update-pve.sh -v 580.95.05 -y

# Dry run — show what would happen, no changes
nvidia-update-pve.sh -v 580.95.05 -n
```

### What it does

1. Downloads (or uses local) the NVIDIA `.run` installer
2. Installs the driver on the PVE host with DKMS support so it survives kernel updates
3. **Secure Boot handling**: if Secure Boot is enabled, generates an RSA-2048 MOK key under `/root/module-signing/`, enrolls it with `mokutil`, and configures DKMS to auto-sign every built module. On next reboot you must confirm enrollment in the UEFI MOK Manager screen.
4. Discovers all LXC containers referencing NVIDIA devices in their config (`/etc/pve/lxc/*.conf`)
5. Pushes the same `.run` file into each affected LXC and installs it with `--no-kernel-modules` (userspace libraries only, as required for LXC GPU sharing)

### Secure Boot notes

If Secure Boot is **enabled**:
- MOK key and certificate are generated under `/root/module-signing/` (skipped if already present)
- You will be prompted by `mokutil` to set a one-time password
- On the **next reboot**, the UEFI MOK Manager will appear — select "Enroll MOK" and enter the password to complete enrollment

If Secure Boot is **disabled**, all signing steps are skipped.

---

## scripts/intel-gpu-audit-pve.sh

Audits and optionally repairs Intel iGPU (i915/xe) passthrough configuration across all LXC containers on a PVE 9.x host. PVE 9.x uses native `dev:` entries in container config rather than `lxc.mount.entry`.

### Requirements

- Run as `root` on the PVE host
- PVE 9.x (Debian 13 / trixie base)
- Intel i915 or xe kernel module loaded on host

### Usage

```bash
# Audit only — report issues, make no changes
intel-gpu-audit-pve.sh

# Audit and auto-remediate all issues
intel-gpu-audit-pve.sh -r

# Non-interactive remediation
intel-gpu-audit-pve.sh -r -y

# Dry run — show what remediation would do
intel-gpu-audit-pve.sh -r -n

# Skip package installation checks
intel-gpu-audit-pve.sh -s

# Add extra packages to check/install per container
intel-gpu-audit-pve.sh -p intel-media-va-driver,vainfo,i965-va-driver
```

### What it checks

**Host:**
1. `i915`/`xe` kernel module loaded
2. `/dev/dri/` device nodes exist with correct permissions
3. `render` and `video` group GIDs present on host

**Per container** (any LXC with `dev: /dev/dri/*` entries):
4. `dev:` entries reference devices that actually exist on the host
5. `dev:` entries have correct GID mappings (`render=993`, `video=44`)
6. `/dev/dri` devices are visible inside the running container
7. `render` group GID inside container matches the host GID
8. Intel userspace packages present (`intel-media-va-driver`, `vainfo`)
9. `vainfo` smoke test — VA-API is functional

### Remediation

With `-r`, the script will:
- Fix incorrect GID mappings in LXC config files (backs up originals to `/root/pve-lxc-conf-backup-YYYYMMDD-HHMMSS/`)
- Restart affected containers as needed
- Install missing Intel VA-API packages inside containers

---

## exporters/unifi_exporter.py

A lightweight Prometheus exporter for UniFi networks. Polls the UniFi controller's native API using an API key — no agent installed on any UniFi device.

### Requirements

- Python 3.8+
- API key from **UniFi OS → Settings → Control Plane → API Keys** (read-only scope sufficient)
- Network access to the UniFi controller (tested against UDM-SE)

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `UNIFI_API_KEY` | *(required)* | API key from UniFi OS Control Plane |
| `UNIFI_HOST` | `192.168.1.1` | UniFi controller IP or hostname |
| `EXPORTER_PORT` | `9916` | Port to expose `/metrics` on |

### Running via Docker (recommended)

```yaml
services:
  unifi-exporter:
    image: python:3.12-slim
    container_name: unifi-exporter
    restart: unless-stopped
    ports:
      - "9916:9916"
    environment:
      - UNIFI_API_KEY=your-api-key-here
      - UNIFI_HOST=192.168.1.1
      - EXPORTER_PORT=9916
    volumes:
      - ./exporter.py:/exporter.py:ro
    command: python3 /exporter.py
```

### Running directly

```bash
UNIFI_API_KEY=your-key UNIFI_HOST=192.168.1.1 python3 exporter.py
```

### Metrics exposed

| Metric | Description |
|---|---|
| `unifi_www_latency_ms` | WAN latency in milliseconds |
| `unifi_www_uptime_seconds` | WAN uptime |
| `unifi_www_xput_up_mbps` / `_down_mbps` | Last speedtest result |
| `unifi_www_tx_bytes_rate` / `_rx_bytes_rate` | WAN throughput (bytes/s) |
| `unifi_wlan_clients{type}` | Wireless client count (user/guest) |
| `unifi_wlan_tx_bytes_rate` / `_rx_bytes_rate` | WLAN aggregate throughput |
| `unifi_lan_clients{type}` | LAN client count |
| `unifi_lan_tx_bytes_rate` / `_rx_bytes_rate` | LAN aggregate throughput |
| `unifi_vpn_users_active` | Active VPN sessions |
| `unifi_vpn_tx_bytes` / `_rx_bytes` | VPN total bytes |
| `unifi_device_uptime{name,model}` | Per-device uptime |
| `unifi_device_cpu_percent{name,model}` | Per-device CPU usage |
| `unifi_device_mem_percent{name,model}` | Per-device memory usage |
| `unifi_device_tx_bytes_rate{name,model}` | Per-device throughput |
| `unifi_ap_clients{name,radio}` | Clients per AP per radio |
| `unifi_ap_satisfaction{name,radio}` | AP client satisfaction score |
| `unifi_ap_tx_retries{name,radio}` | AP TX retries |
| `unifi_switch_port_tx_bytes{device,port}` | Switch port TX bytes total |
| `unifi_switch_port_rx_bytes{device,port}` | Switch port RX bytes total |
| `unifi_switch_port_speed{device,port}` | Switch port negotiated speed |
| `unifi_switch_port_tx_errors{device,port}` | Switch port TX errors |
| `unifi_switch_port_rx_errors{device,port}` | Switch port RX errors |
| `unifi_clients_total{type}` | Total clients (wired/wireless/total) |
| `unifi_wlan_avg_rssi_dbm` | Average RSSI across all wireless clients |

### Prometheus scrape config

```yaml
scrape_configs:
  - job_name: 'unifi'
    static_configs:
      - targets: ['<exporter-host>:9916']
        labels:
          instance: 'udm-se'
```

### Cache

Metrics are cached for 15 seconds to avoid hammering the controller API on every Prometheus scrape.
