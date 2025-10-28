#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
log setup "netns: rp_filter relax for ${VETH_NS}, ${TS_IF}"

require_prio_ns
require_tailscale_in_ns
ip netns exec "${NS}" sh -c "
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.${VETH_NS}.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.${TS_IF}.rp_filter=2 >/dev/null
"
