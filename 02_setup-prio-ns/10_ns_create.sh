#!/usr/bin/env bash
. "$(dirname "$0")/00_common.sh"; as_root; log setup "NS/veth 생성"

ns_exists || { ip netns add "${NS}"; log setup "ns ${NS} 생성"; }

if ! exists_link "${VETH_MAIN}"; then
  ip link add "${VETH_MAIN}" type veth peer name "${VETH_NS}"
  ip link set "${VETH_NS}" netns "${NS}"
  log setup "veth ${VETH_MAIN} <-> ${VETH_NS}@${NS} 생성"
fi

ip addr show dev "${VETH_MAIN}" | grep -q "${HOST_VETH_IP}" || ip addr add "${MAIN_IP_CIDR}" dev "${VETH_MAIN}"
ip link set "${VETH_MAIN}" up

ns_link_exists "${VETH_NS}" || die "missing ${VETH_NS} in ${NS}"
ip netns exec "${NS}" ip addr show dev "${VETH_NS}" | grep -q "${NS_IP_CIDR%/*}" || \
  ip netns exec "${NS}" ip addr add "${NS_IP_CIDR}" dev "${VETH_NS}"
ip netns exec "${NS}" ip link set "${VETH_NS}" up
