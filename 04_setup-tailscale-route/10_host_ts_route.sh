#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log setup "host: route ${TS_CIDR} -> ${NS_VETH_IP} via ${VETH_MAIN} & rp_filter relax"

require_prio_ns
ip route replace "${TS_CIDR}" via "${NS_VETH_IP}" dev "${VETH_MAIN}"

sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
sysctl -w "net.ipv4.conf.${VETH_MAIN}.rp_filter=2" >/dev/null
