#!/usr/bin/env bash
. "$(dirname "$0")/00_common.sh"; as_root; log setup "기본 라우팅(main 우선)"

source .bearer_ipv4 || true
ip netns exec "${NS}" sh -c '
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.'"${LTE_IF}"'.rp_filter=2 >/dev/null
' || true

ip netns exec "${NS}" ip route replace "${HOST_VETH_IP}/32" dev "${VETH_NS}"
[ -n "${GW:-}" ] && ip netns exec "${NS}" ip route replace "${GW}" dev "${LTE_IF}" || true

ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10
if [ -n "${GW:-}" ]; then
  ip netns exec "${NS}" ip route replace default via "${GW}" dev "${LTE_IF}" onlink metric 100
else
  log setup "LTE GW 없음: LTE 기본경로 skip(블랙홀 방지)"
fi
