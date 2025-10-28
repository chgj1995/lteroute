#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log setup "netns: NAT & FORWARD rules ( ${VETH_NS} <-> ${TS_IF} )"

require_prio_ns
ip netns exec "${NS}" bash -c "
  iptables -C FORWARD -i ${VETH_NS} -o ${TS_IF} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i ${VETH_NS} -o ${TS_IF} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  iptables -C FORWARD -i ${TS_IF} -o ${VETH_NS} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i ${TS_IF} -o ${VETH_NS} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -t nat -C POSTROUTING -s ${HOST_VETH_IP}/30 -o ${TS_IF} -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s ${HOST_VETH_IP}/30 -o ${TS_IF} -j MASQUERADE
"
