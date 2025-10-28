#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log uninstall "removing rules (best effort)"

UNIT="/etc/systemd/system/tailscale-route-restore.service"
systemctl disable --now tailscale-route-restore.service >/dev/null 2>&1 || true
rm -f "${UNIT}"; systemctl daemon-reload || true

ip route del "${TS_CIDR}" via "${NS_VETH_IP}" dev "${VETH_MAIN}" >/dev/null 2>&1 || true

if ns_exists; then
  ip netns exec "${NS}" bash -c "
    iptables -t nat -F || true
    iptables -F || true
  " || true
fi

log uninstall "done"
