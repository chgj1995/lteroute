#!/usr/bin/env bash
set -Eeuo pipefail

NS=prio_ns
ip netns exec "$NS" bash -lc '
  iptables -t nat -C POSTROUTING -o wwan0 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o wwan0 -j MASQUERADE

  iptables -C FORWARD -i veth-ns -o wwan0 -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i veth-ns -o wwan0 -j ACCEPT

  iptables -C FORWARD -i wwan0 -o veth-ns -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i wwan0 -o veth-ns -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
'
echo "[setup] netns: NAT & FORWARD rules ( veth-ns <-> wwan0 )"
