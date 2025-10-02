#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== 03_install-tailscale =="
run(){ local f="$1"; echo "==> $(basename "$f")"; bash "$f"; }

steps=(10_install_package.sh 20_override_unit.sh 30_reload_restart.sh 35_wait_tailscale0.sh 40_disable_magicdns_host.sh 50_restore_host_dns.sh)
for f in "${steps[@]}"; do run "$DIR/$f"; done

echo
echo "로그인(필요시):"
echo "  sudo ip netns exec prio_ns tailscale up --authkey=<YOUR_KEY> --hostname=$(hostname)-ns"
echo "상태 확인:"
echo "  sudo ip netns exec prio_ns tailscale status"
