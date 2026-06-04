# homelab-scripts

Scripts, exporters and dashboards for the retiarius.co.nz homelab.

## Structure

- `exporters/` — Prometheus exporters
  - `unifi_exporter.py` — UniFi UDM-SE native API exporter (no agent on device)
- `scripts/` — PVE deployment scripts
  - `deploy-node-exporter.sh` — deploys prometheus-node-exporter to all running LXCs via pct exec
- `dashboards/` — Grafana dashboard JSON

## Usage on PVE

```bash
# Clone on PVE host
git clone https://github.com/BadgerBadgerAndFox/homelab-scripts.git /opt/homelab-scripts

# Deploy node_exporter to all LXCs
bash /opt/homelab-scripts/scripts/deploy-node-exporter.sh

# Update
cd /opt/homelab-scripts && git pull
```
