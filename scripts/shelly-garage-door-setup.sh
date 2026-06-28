#!/usr/bin/env bash
#
# shelly-garage-door-setup.sh
#
# Configures a Shelly Plus 1 + standard Sensor Add-on as a garage door
# pulse-relay controller with two position sensors:
#   - input:100 (digital_in, addon DI terminal)  -> CLOSE sensor (reed switch)
#   - input:101 (analog_in,  addon AI terminal)   -> OPEN  sensor (reed switch)
#
# NOTE: The standard (non-Pro) Shelly Sensor Add-on only exposes ONE true
# digital input + ONE analog input + ONE 1-wire bus. Two genuine digital_in
# peripherals are NOT available on this hardware combo (that requires
# ShellyPlusI4 or a Pro device + ProSensorAddon). This script wires the
# second sensor to the analog input and treats it as a threshold/boolean
# input on the Home Assistant side. See README in this folder / chat for
# full explanation.
#
# Usage: ./shelly-garage-door-setup.sh <shelly-ip>

set -euo pipefail

SHELLY_IP="${1:?Usage: $0 <shelly-ip>}"
BASE="http://${SHELLY_IP}/rpc"

rpc() {
  local method="$1"
  local params="$2"
  curl -sS -X POST "${BASE}" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":1,\"src\":\"garage-door-setup\",\"method\":\"${method}\",\"params\":${params}}"
}

echo "==> 1. Enabling Sensor Add-on (device.addon_type = sensor)"
rpc "Sys.SetConfig" '{"config":{"device":{"addon_type":"sensor"}}}'
echo
echo "    Add-on enabled. Device will need a reboot before peripherals can be added."
echo "    Run: curl -sS -X POST ${BASE} -d '{\"id\":1,\"method\":\"Shelly.Reboot\"}'"
read -rp "    Press Enter once the device has rebooted to continue..." _

echo "==> 2. Adding digital input peripheral (CLOSE sensor) -> input:100"
rpc "SensorAddon.AddPeripheral" '{"type":"digital_in","attrs":{"cid":100}}'
echo

echo "==> 3. Adding analog input peripheral (OPEN sensor) -> input:101"
rpc "SensorAddon.AddPeripheral" '{"type":"analog_in","attrs":{"cid":101}}'
echo

echo "==> 4. Configuring input:100 (CLOSE sensor) as a stateful switch input"
echo "    Set invert:true here if the sensor reads inverted vs. expected (test physically)."
rpc "Input.SetConfig" '{"id":100,"config":{"name":"Garage Close Sensor","type":"switch","invert":false}}'
echo

echo "==> 5. Setting analog report threshold for input:101 (OPEN sensor)"
echo "    Lower this if the open/closed transition doesn't register reliably."
rpc "Input.SetConfig" '{"id":101,"config":{"name":"Garage Open Sensor","type":"analog","report_thr":5}}'
echo

echo "==> 6. Detaching the relay (switch:0) from the local input/button"
echo "    so the addon sensors never drive the relay directly -- only RPC/HA pulses it."
rpc "Switch.SetConfig" '{"id":0,"config":{"name":"Garage Door Relay","in_mode":"detached","initial_state":"off"}}'
echo

echo "==> Done. Relay is pulsed on demand from Home Assistant via:"
echo '    Switch.Set {"id":0,"on":true,"toggle_after":0.5}'
echo
echo "    See home-assistant/garage-door-cover.yaml for the template cover + automations"
echo "    that turn switch:0 + input:100 + input:101 into a single garage door entity."
