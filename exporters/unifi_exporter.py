#!/usr/bin/env python3
import time, ssl, json, os, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

API_KEY = os.environ.get('UNIFI_API_KEY', '')
HOST = os.environ.get('UNIFI_HOST', '192.168.1.1')
PORT = int(os.environ.get('EXPORTER_PORT', '9916'))
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
CACHE = {'data': '', 'ts': 0}

def api(path):
    url = f'https://{HOST}/proxy/network/api/s/default/{path}'
    req = urllib.request.Request(url, headers={'X-API-KEY': API_KEY})
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.loads(r.read())['data']

def g(name, val, labels=''):
    if val is None: return ''
    lb = f'{{{labels}}}' if labels else ''
    return f'unifi_{name}{lb} {val}\n'

def collect():
    out = []
    try:
        for s in api('stat/health'):
            sub = s.get('subsystem', '')
            if sub == 'www':
                out += [g('www_latency_ms', s.get('latency'), 'site="default"'),
                        g('www_uptime_seconds', s.get('uptime'), 'site="default"'),
                        g('www_xput_up_mbps', s.get('xput_up'), 'site="default"'),
                        g('www_xput_down_mbps', s.get('xput_down'), 'site="default"'),
                        g('www_tx_bytes_rate', s.get('tx_bytes-r'), 'site="default"'),
                        g('www_rx_bytes_rate', s.get('rx_bytes-r'), 'site="default"')]
            elif sub == 'wlan':
                out += [g('wlan_clients', s.get('num_user'), 'type="user",site="default"'),
                        g('wlan_clients', s.get('num_guest'), 'type="guest",site="default"'),
                        g('wlan_tx_bytes_rate', s.get('tx_bytes-r'), 'site="default"'),
                        g('wlan_rx_bytes_rate', s.get('rx_bytes-r'), 'site="default"')]
            elif sub == 'lan':
                out += [g('lan_clients', s.get('num_user'), 'type="user",site="default"'),
                        g('lan_tx_bytes_rate', s.get('tx_bytes-r'), 'site="default"'),
                        g('lan_rx_bytes_rate', s.get('rx_bytes-r'), 'site="default"')]
            elif sub == 'vpn':
                out += [g('vpn_users_active', s.get('remote_user_num_active'), 'site="default"'),
                        g('vpn_tx_bytes', s.get('remote_user_tx_bytes'), 'site="default"'),
                        g('vpn_rx_bytes', s.get('remote_user_rx_bytes'), 'site="default"')]
    except Exception as e:
        out.append(f'# health error: {e}\n')

    try:
        for d in api('stat/device'):
            n = d.get('name', '').replace('"', '')
            m = d.get('model', '').replace('"', '')
            lb = f'name="{n}",model="{m}"'
            out += [g('device_uptime', d.get('uptime'), lb),
                    g('device_tx_bytes', d.get('tx_bytes'), lb),
                    g('device_rx_bytes', d.get('rx_bytes'), lb),
                    g('device_tx_bytes_rate', d.get('tx_bytes-r'), lb),
                    g('device_rx_bytes_rate', d.get('rx_bytes-r'), lb)]
            ss = d.get('system-stats', {})
            if ss:
                out += [g('device_cpu_percent', ss.get('cpu'), lb),
                        g('device_mem_percent', ss.get('mem'), lb)]
            for radio in d.get('radio_table_stats', []):
                rl = f'name="{n}",radio="{radio.get("name","")}"'
                out += [g('ap_clients', radio.get('num_sta'), rl),
                        g('ap_tx_bytes_rate', radio.get('tx_bytes-r'), rl),
                        g('ap_rx_bytes_rate', radio.get('rx_bytes-r'), rl),
                        g('ap_tx_retries', radio.get('tx_retries'), rl),
                        g('ap_satisfaction', radio.get('satisfaction'), rl)]
            for p in d.get('port_table', []):
                if not p.get('up'): continue
                pl = f'device="{n}",port="{p.get("name","")}"'
                out += [g('switch_port_tx_bytes', p.get('tx_bytes'), pl),
                        g('switch_port_rx_bytes', p.get('rx_bytes'), pl),
                        g('switch_port_tx_bytes_rate', p.get('tx_bytes-r'), pl),
                        g('switch_port_rx_bytes_rate', p.get('rx_bytes-r'), pl),
                        g('switch_port_speed', p.get('speed'), pl),
                        g('switch_port_tx_errors', p.get('tx_errors'), pl),
                        g('switch_port_rx_errors', p.get('rx_errors'), pl),
                        g('switch_port_tx_dropped', p.get('tx_dropped'), pl)]
    except Exception as e:
        out.append(f'# device error: {e}\n')

    try:
        clients = api('stat/sta')
        wired = [c for c in clients if c.get('is_wired')]
        wireless = [c for c in clients if not c.get('is_wired')]
        out += [f'unifi_clients_total{{type="wired",site="default"}} {len(wired)}\n',
                f'unifi_clients_total{{type="wireless",site="default"}} {len(wireless)}\n',
                f'unifi_clients_total{{type="total",site="default"}} {len(clients)}\n']
        rssi = [c.get('rssi', 0) for c in wireless if c.get('rssi')]
        if rssi:
            out.append(g('wlan_avg_rssi_dbm', round(sum(rssi)/len(rssi), 1), 'site="default"'))
    except Exception as e:
        out.append(f'# client error: {e}\n')

    return ''.join(x for x in out if x)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path != '/metrics':
            self.send_response(404); self.end_headers(); return
        now = time.time()
        if now - CACHE['ts'] > 15:
            CACHE['data'] = collect()
            CACHE['ts'] = now
        body = CACHE['data'].encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    print(f'UniFi exporter listening on :{PORT}')
    HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
