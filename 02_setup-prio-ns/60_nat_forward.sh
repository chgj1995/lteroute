#!/usr/bin/env bash
. "$(dirname "$0")/00_common.sh"; as_root; log setup "호스트 NAT/Forward"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
for OUT in "${CHECK_OUT_IFS[@]}"; do
  iptables -C -t nat POSTROUTING -o "${OUT}" -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -o "${OUT}" -j MASQUERADE
done
# Docker 등 다른 규칙보다 우선 적용하기 위해 체인 맨 앞에 규칙을 '삽입'(-I)합니다.
iptables -C FORWARD -i "${VETH_MAIN}" -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD 1 -i "${VETH_MAIN}" -j ACCEPT
iptables -C FORWARD -o "${VETH_MAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || \
  iptables -I FORWARD 1 -o "${VETH_MAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT