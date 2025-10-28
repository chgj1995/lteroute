#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== setup ntpdate in ns install =="

# 1) 신규 서비스/타이머 유닛 생성 스크립트 실행
bash "$DIR/10_create_ntp_service.sh"

# 2) Systemd 리로드 및 신규 타이머 활성화
echo "Reloading systemd daemon and enabling ntpdate-in-ns.timer..."
systemctl daemon-reload
systemctl enable --now ntpdate-in-ns.timer

echo "== done =="
