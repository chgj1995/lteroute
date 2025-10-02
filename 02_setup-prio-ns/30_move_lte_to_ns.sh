#!/usr/bin/env bash
. "$(dirname "$0")/00_common.sh"; as_root; log setup "LTE 인터페이스 NS 이동/적용"

source .bearer_ipv4 || true
exists_link "${LTE_IF}" && ip link set "${LTE_IF}" netns "${NS}"
ip netns exec "${NS}" ip link set "${LTE_IF}" up

[ -n "${ADDR:-}" ] && [ -n "${PFX:-}" ] && {
  ip netns exec "${NS}" ip addr flush dev "${LTE_IF}" || true
  ip netns exec "${NS}" ip addr add "${ADDR}/${PFX}" dev "${LTE_IF}"
  [ -n "${MTU:-}" ] && ip netns exec "${NS}" ip link set "${LTE_IF}" mtu "${MTU}" || true
}
[ -n "${GW:-}" ] && ip netns exec "${NS}" ip route replace "${GW}" dev "${LTE_IF}" || true
