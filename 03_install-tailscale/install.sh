#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== 03_install-tailscale =="
run(){ local f="$1"; echo "==> $(basename "$f")"; bash "$f"; }

# prio_ns 관련 스크립트들을 제거하고 실행 단계를 단순화
steps=(10_install_package.sh 20_override_unit.sh 30_reload_restart.sh)
for f in "${steps[@]}"; do run "$DIR/$f"; done

echo
echo "로그인(필요시):"
echo "  sudo tailscale up --authkey=<YOUR_KEY> --hostname=$(hostname)"
echo "상태 확인:"
echo "  sudo tailscale status"
