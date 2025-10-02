#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log save "saving host routes & ns iptables"
require_prio_ns

echo "${TS_CIDR} via ${NS_VETH_IP} dev ${VETH_MAIN}" > "${STATE_DIR}/host_route.txt"
ip netns exec "${NS}" iptables-save > "${STATE_DIR}/iptables_ns_all.save"
ip netns exec "${NS}" iptables-save -t nat > "${STATE_DIR}/iptables_ns_nat.save" || true
ip netns exec "${NS}" iptables-save -t filter > "${STATE_DIR}/iptables_ns_filter.save" || true

{
  sysctl -n net.ipv4.conf.all.rp_filter || true
  sysctl -n net.ipv4.conf.default.rp_filter || true
  sysctl -n "net.ipv4.conf.${VETH_MAIN}.rp_filter" || true
} > "${STATE_DIR}/host_rpf.txt" 2>/dev/null || true

ip netns exec "${NS}" sh -c "
  sysctl -n net.ipv4.conf.all.rp_filter || true
  sysctl -n net.ipv4.conf.default.rp_filter || true
  sysctl -n net.ipv4.conf.${VETH_NS}.rp_filter || true
  sysctl -n net.ipv4.conf.${TS_IF}.rp_filter || true
" > "${STATE_DIR}/ns_rpf.txt" 2>/dev/null || true

log save "state saved under ${STATE_DIR}/"
