#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log setup "netns: DNAT ${TS_IF}:[${APP_PORTS}] -> ${HOST_VETH_IP}:[${APP_PORTS}]"

require_prio_ns
require_tailscale_in_ns
for port in ${APP_PORTS}; do
  ip netns exec "${NS}" bash -c '
    set -euo pipefail
    P="$1"; TS_IF="$2"; HOST_VETH_IP="$3"; VETH_NS="$4"
    # DNAT: tailscale0:$P -> veth-main:$P
    iptables -t nat -C PREROUTING -i "$TS_IF" -p tcp --dport "$P" -j DNAT --to-destination "$HOST_VETH_IP":"$P" 2>/dev/null || \
      iptables -t nat -A PREROUTING -i "$TS_IF" -p tcp --dport "$P" -j DNAT --to-destination "$HOST_VETH_IP":"$P"

    # FORWARD: DNAT된 패킷 허용
    iptables -C FORWARD -i "$TS_IF" -o "$VETH_NS" -p tcp --dport "$P" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i "$TS_IF" -o "$VETH_NS" -p tcp --dport "$P" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  ' bash "$port" "${TS_IF}" "${HOST_VETH_IP}" "${VETH_NS}"
done
