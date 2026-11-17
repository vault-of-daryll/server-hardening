#!/usr/bin/env bash
# Attack lab: runs tests/vm-test.sh --keep with a second network card on the VM, plugged into your
# home network through this machine's wired interface (macvtap). Another machine on the same network
# can then scan the hardened VM like a separate server. This machine itself cannot reach the VM's
# lab address (a macvtap limit); Ansible still uses the forwarded port. Needs sudo, wired Ethernet.
#   bash tests/vm-lab.sh <interface>     # e.g. enp3s0; list them with: ip -br link
#   bash tests/vm-lab.sh --stop          # stop the VM and remove the lab interface
set -uo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
work=${VM_WORK:-$HOME/.cache/hardening-vm}
image=${VM_IMAGE:-ubuntu-26.04}
[ "$image" = ubuntu-26.04 ] || work=$work/$image
lab=hvlab0

matches_process() {
  local pid=$1 kind=$2 cmd
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  [ "$(readlink -f "/proc/$pid/cwd")" = "$(readlink -f "$work")" ] || return 1
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  case "$kind:$cmd" in
    qemu:*qemu-system*file=disk.qcow2*) return 0 ;;
    http:*python*' -m http.server '*' --directory seed '*) return 0 ;;
  esac
  return 1
}

stop_process() {
  local kind=$1 pid
  [ -f "$work/$kind.pid" ] || return 0
  pid=$(cat "$work/$kind.pid")
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "Invalid $kind PID; refusing to signal it"; return 1; }
  kill -0 "$pid" 2>/dev/null || { rm -f "$work/$kind.pid"; return 0; }
  matches_process "$pid" "$kind" || { echo "Saved $kind PID belongs to another process; refusing to signal it"; return 1; }
  kill "$pid" || return 1
  for _ in $(seq 100); do
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$work/$kind.pid"; return 0; fi
    sleep 0.1
  done
  echo "$kind did not exit; its state has been kept"
  return 1
}

if [ "${1:-}" = "--stop" ]; then
  stop_process qemu || { echo "QEMU is not confirmed stopped; keeping disk.qcow2 and the lab interface"; exit 1; }
  stop_process http || exit 1
  rm -f "$work/disk.qcow2"
  if ip link show "$lab" >/dev/null 2>&1; then sudo ip link del "$lab" || exit 1; fi
  echo "Lab stopped"; exit 0
fi

if { [ -f "$work/qemu.pid" ] && pid=$(cat "$work/qemu.pid") &&
     [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
     tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q qemu-system; } || ip link show "$lab" >/dev/null 2>&1; then
  echo "A lab VM for this image is running or $lab already exists; run bash tests/vm-lab.sh --stop first"
  exit 1
fi

iface=${1:?usage: bash tests/vm-lab.sh <wired interface>   (list: ip -br link)}
[ -d "/sys/class/net/$iface" ] || { echo "No interface $iface; list them with: ip -br link"; exit 1; }
# Wi-Fi access points drop frames from a second MAC address, so the VM would never get an address.
[ -d "/sys/class/net/$iface/wireless" ] && { echo "$iface is Wi-Fi; macvtap needs a wired interface"; exit 1; }
[ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" = 1 ] || { echo "$iface has no cable link; plug it into the router first"; exit 1; }

mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
sudo ip link add link "$iface" name "$lab" address "$mac" type macvtap mode bridge || exit 1
sudo ip link set "$lab" up || exit 1
tap=/dev/tap$(cat "/sys/class/net/$lab/ifindex")
if command -v udevadm >/dev/null 2>&1; then udevadm settle || exit 1; fi
sudo chown "$USER" "$tap" || exit 1

VM_LAB_TAP=$tap VM_LAB_MAC=$mac bash "$kit/tests/vm-test.sh" --keep; status=$?
if ! { [ -f "$work/qemu.pid" ] && kill -0 "$(cat "$work/qemu.pid")" 2>/dev/null; }; then
  sudo ip link del "$lab" 2>/dev/null; echo "The VM is not running; lab interface removed"; exit 1
fi

ip=$(ssh -o UserKnownHostsFile="$work/known_hosts" -o BatchMode=yes -i "$work/key" -p "${VM_PORT:-2230}" deploy@127.0.0.1 \
  "ip -4 -o addr show lab0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null)
echo
echo "Lab VM address on your network: ${ip:-unknown (check: ssh into the VM, then ip -br addr)}"
echo "Scan it from another machine, for example:  sudo nmap -Pn -sS -sU --top-ports 200 ${ip:-<address>}"
echo "Stop the lab:  bash tests/vm-lab.sh --stop"
exit "$status"
