#!/usr/bin/env bash
. "$(dirname "$0")/00_common.sh"; as_root; log setup "호스트 NAT/Forward"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
for OUT in "${CHECK_OUT_IFS[@]}"; do
  iptables -C -t nat POSTROUTING -o "${OUT}" -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -o "${OUT}" -j MASQUERADE
done
iptables -C FORWARD -i "${VETH_MAIN}" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -i "${VETH_MAIN}" -j ACCEPT
# prio_ns로 돌아오는 트래픽 허용 (ping 응답 등)
iptables -C FORWARD -o "${VETH_MAIN}" -j ACCEPT >/dev/null 2>&1 || \
  iptables -A FORWARD -o "${VETH_MAIN}" -j ACCEPT
