#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log setup "netns: DNAT ${TS_IF}:${APP_PORT} -> ${HOST_VETH_IP}:${APP_PORT}"

require_prio_ns
require_tailscale_in_ns
ip netns exec "${NS}" bash -c "
  # DNAT: tailscale0:${APP_PORT} -> veth-main:${APP_PORT}
  iptables -t nat -C PREROUTING -i ${TS_IF} -p tcp --dport ${APP_PORT} -j DNAT --to-destination ${HOST_VETH_IP}:${APP_PORT} 2>/dev/null || \
    iptables -t nat -A PREROUTING -i ${TS_IF} -p tcp --dport ${APP_PORT} -j DNAT --to-destination ${HOST_VETH_IP}:${APP_PORT}

  # FORWARD: DNAT된 패킷 허용
  iptables -C FORWARD -i ${TS_IF} -o ${VETH_NS} -p tcp --dport ${APP_PORT} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i ${TS_IF} -o ${VETH_NS} -p tcp --dport ${APP_PORT} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
"
