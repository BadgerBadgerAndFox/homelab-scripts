#!/usr/bin/env bash
#
# shelly-garage-door-setup.sh
#
# STATUS (2026-06-28): Already applied and confirmed against the live
# device — shellyplus1-cc7b5c0beb80 (MAC CC:7B:5C:0B:EB:80), 192.168.4.201.
# Confirmed via Switch.GetConfig / Input.GetConfig:
#   switch:0   in_mode=detached, initial_state=off, auto_off=true (1.0s) -- relay auto-cuts as a second safety net beyond HA's 500ms pulse script
#   input:0    type=switch  (CLOSE sensor)
#   input:100  type=switch  (OPEN sensor)
# This script is kept for reference / re-provisioning a replacement unit.
#
# Configures a Shelly Plus 1 + Sensor Add-on as a garage door pulse-relay
# controller with two position sensors:
#   - input:0   (built-in SW terminal, decoupled from switch:0) -> CLOSE sensor
#   - input:100 (digital_in, addon DI terminal)                  -> OPEN  sensor
#
# switch:0 (the relay) only ever pulses the door -- it is decoupled
# (in_mode: detached) from input:0 so the built-in input can be repurposed
# as a pure position sensor instead of a button that drives the relay.
# The addon's analog input (would-be input:101) is NOT used in this setup.
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

echo "==> 2. Adding digital input peripheral (OPEN sensor) -> input:100"
rpc "SensorAddon.AddPeripheral" '{"type":"digital_in","attrs":{"cid":100}}'
echo

echo "==> 3. Configuring input:100 (OPEN sensor) as a stateful switch input"
echo "    Set invert:true here if the sensor reads inverted vs. expected (test physically)."
rpc "Input.SetConfig" '{"id":100,"config":{"name":"Garage Open Sensor","type":"switch","invert":false}}'
echo

echo "==> 4. Decoupling the relay (switch:0) from the built-in input (input:0)"
echo "    so input:0 stops driving the relay and can be repurposed as a pure sensor."
rpc "Switch.SetConfig" '{"id":0,"config":{"name":"Garage Door Relay","in_mode":"detached","initial_state":"off"}}'
echo

echo "==> 5. Configuring input:0 (built-in terminal) as the CLOSE sensor"
echo "    Set invert:true here if the sensor reads inverted vs. expected (test physically)."
rpc "Input.SetConfig" '{"id":0,"config":{"name":"Garage Close Sensor","type":"switch","invert":false}}'
echo

echo "==> Done. Relay is pulsed on demand from Home Assistant via:"
echo '    Switch.Set {"id":0,"on":true,"toggle_after":0.5}'
echo
echo "    See home-assistant/garage-door-cover.yaml for the template cover + automations"
echo "    that turn switch:0 + input:0 + input:100 into a single garage door entity, plus"
echo "    the HomeKit bridge config entry and the matterbridge-shelly blacklist entry"
echo "    needed to avoid a duplicate Matter accessory for the same device."
