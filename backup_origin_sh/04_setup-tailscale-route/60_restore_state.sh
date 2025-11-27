#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log restore "restoring host route & ns iptables (idempotent)"

require_prio_ns
require_tailscale_in_ns

if [ -s "${STATE_DIR}/host_route.txt" ]; then
  route_line="$(cat "${STATE_DIR}/host_route.txt")"
  ip route replace ${route_line}
fi

if [ -s "${STATE_DIR}/iptables_ns_all.save" ]; then
  ip netns exec "${NS}" iptables-restore < "${STATE_DIR}/iptables_ns_all.save"
else
  log restore "iptables_ns_all.save not found; applying steps"
  bash "$(dirname "$0")/30_nat_forward.sh"
  bash "$(dirname "$0")/40_dnat_app.sh"
fi

bash "$(dirname "$0")/20_ns_rpf.sh" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
sysctl -w "net.ipv4.conf.${VETH_MAIN}.rp_filter=2" >/dev/null

log restore "done"
