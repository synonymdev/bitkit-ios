#!/usr/bin/env bash
# One fresh Ubuntu runner owns one regtest chain for one simulator job.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
cd "${E2E_DIR:-bitkit-e2e-tests}"
export E2E_DIR="$PWD" BITCOIN_FALLBACK_FEE=0.00001 TREZOR_RANDOM_MNEMONIC=true
cleanup() {
  ./scripts/local-backend down --remove-orphans -v -t 10 >/dev/null 2>&1 || true
}
trap cleanup EXIT
# Filter on ingress before Docker DNAT. Only this Mac can use the control/CONNECT
# port. The service forwards locally, even when the fixture publishes wildcard ports.
export HOSTED_MAC_IP
HOSTED_MAC_IP=$(python3 "$scripts/hosted-e2e-pair.py" mac-ip)
tailnet_ip=$(tailscale ip -4)
iface=$(ip -j -4 addr show | jq -er --arg ip "$tailnet_ip" '.[] | select(any(.addr_info[]; .local == $ip)) | .ifname')
sudo iptables -t raw -N BITKIT_HOSTED_PAIR
sudo iptables -t raw -A BITKIT_HOSTED_PAIR -s "$HOSTED_MAC_IP" -p tcp --dport 8081 -j RETURN
sudo iptables -t raw -A BITKIT_HOSTED_PAIR -j DROP
sudo iptables -t raw -I PREROUTING -i "$iface" -j BITKIT_HOSTED_PAIR
sudo ip6tables -t raw -I PREROUTING -i "$iface" -j DROP
# Reserve the published ports before image pulls can consume an ephemeral port.
sudo sysctl -w net.ipv4.ip_local_reserved_ports=23009,23180,23735,39388,43782,60001
./scripts/local-backend up
export BITKIT_LOCAL_BACKEND_ROOT
BITKIT_LOCAL_BACKEND_ROOT=$(./scripts/local-backend path)
if [[ "$SHARD" == 2 ]]; then
  # The Linux profile shares host networking with the regtest stack.
  "$BITKIT_LOCAL_BACKEND_ROOT/scripts/trezor-emulator" start --json >/dev/null 2>&1 || {
    echo '::error::Could not initialize the Linux Trezor fixture'
    exit 1
  }
fi
python3 "$scripts/hosted-e2e-pair.py" serve
