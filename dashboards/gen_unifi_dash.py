import json
DS={"type":"prometheus","uid":"PBFA97CFB590B2093"}
def stat(id,x,y,w,h,tt,u,ex,wn=None,cr=None):
    steps=[{"color":"green","value":None}]
    if wn:steps.append({"color":"yellow","value":wn})
    if cr:steps.append({"color":"red","value":cr})
    return{"id":id,"gridPos":{"x":x,"y":y,"w":w,"h":h},"type":"stat","title":tt,
        "options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none"},
        "fieldConfig":{"defaults":{"unit":u,"thresholds":{"mode":"absolute","steps":steps}}},
        "targets":[{"datasource":DS,"expr":ex,"legendFormat":tt}]}
def ts(id,x,y,w,h,tt,u,tgts):
    return{"id":id,"gridPos":{"x":x,"y":y,"w":w,"h":h},"type":"timeseries","title":tt,
        "fieldConfig":{"defaults":{"unit":u,"custom":{"lineWidth":2,"fillOpacity":10}}},
        "targets":[{"datasource":DS,"expr":e,"legendFormat":l} for e,l in tgts]}
def row(id,y,tt):
    return{"id":id,"gridPos":{"x":0,"y":y,"w":24,"h":1},"type":"row","title":tt,"collapsed":False}
I='instance="udm-se"'
P=[
 stat(1,0,0,4,3,"WAN Latency","ms",f'unifi_www_latency_ms{{{I}}}',10,50),
 stat(2,4,0,4,3,"WAN Uptime","s",f'unifi_www_uptime_seconds{{{I}}}'),
 stat(3,8,0,3,3,"WiFi Clients","short",f'unifi_wlan_clients{{type="user",{I}}}',40,60),
 stat(4,11,0,3,3,"LAN Clients","short",f'unifi_lan_clients{{type="user",{I}}}'),
 stat(5,14,0,3,3,"VPN Active","short",f'unifi_vpn_users_active{{{I}}}'),
 stat(6,17,0,4,3,"Speedtest Up","Mbps",f'unifi_www_xput_up_mbps{{{I}}}'),
 stat(7,21,0,3,3,"Speedtest Down","Mbps",f'unifi_www_xput_down_mbps{{{I}}}'),
 row(10,3,"WAN & Site"),
]
P+=[
 ts(11,0,4,12,8,"WAN Throughput","Bps",[(f'unifi_www_tx_bytes_rate{{{I}}}','TX'),(f'unifi_www_rx_bytes_rate{{{I}}}','RX')]),
 ts(12,12,4,12,8,"Clients","short",[(f'unifi_wlan_clients{{type="user",{I}}}','WiFi'),(f'unifi_lan_clients{{type="user",{I}}}','LAN')]),
 row(20,12,"Wireless"),
 ts(21,0,13,12,8,"WLAN Throughput","Bps",[(f'unifi_wlan_tx_bytes_rate{{{I}}}','TX'),(f'unifi_wlan_rx_bytes_rate{{{I}}}','RX')]),
 ts(22,12,13,12,8,"AP Clients","short",[('unifi_ap_clients','{{name}} {{radio}}')]),
 ts(23,0,21,12,8,"AP Satisfaction %","percent",[('unifi_ap_satisfaction','{{name}} {{radio}}')]),
 ts(24,12,21,12,8,"AP TX Retries","short",[('unifi_ap_tx_retries','{{name}} {{radio}}')]),
]
P+=[
 row(30,29,"Devices"),
 ts(31,0,30,12,8,"Device CPU %","percent",[('unifi_device_cpu_percent','{{name}}')]),
 ts(32,12,30,12,8,"Device Memory %","percent",[('unifi_device_mem_percent','{{name}}')]),
 ts(33,0,38,24,8,"Device Throughput","Bps",[('unifi_device_tx_bytes_rate','{{name}} TX'),('unifi_device_rx_bytes_rate','{{name}} RX')]),
 row(40,46,"Switch Ports"),
 ts(41,0,47,24,8,"Top Port Throughput","Bps",[('topk(10,unifi_switch_port_tx_bytes_rate)','{{device}} {{port}} TX'),('topk(10,unifi_switch_port_rx_bytes_rate)','{{device}} {{port}} RX')]),
 ts(42,0,55,12,8,"Switch Errors","short",[('unifi_switch_port_tx_errors','{{device}} {{port}} TX'),('unifi_switch_port_rx_errors','{{device}} {{port}} RX')]),
 ts(43,12,55,12,8,"Total Clients","short",[(f'unifi_clients_total{{type="total",{I}}}','Total'),(f'unifi_clients_total{{type="wired",{I}}}','Wired'),(f'unifi_clients_total{{type="wireless",{I}}}','Wireless')]),
]
dash={"title":"UniFi Network","uid":"homelab-unifi-v1","tags":["unifi","network","homelab"],
    "timezone":"browser","refresh":"30s","time":{"from":"now-3h","to":"now"},"panels":P}
with open('/tmp/unifi_dashboard.json','w') as f: json.dump(dash,f)
print('ok',len(json.dumps(dash)))
