#!/usr/bin/env bash
set -Eeuo pipefail

as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== setup ntpdate in ns uninstall =="

SERVICE_FILE="/etc/systemd/system/ntpdate-in-ns.service"
TIMER_FILE="/etc/systemd/system/ntpdate-in-ns.timer"

# 1) 신규 타이머 비활성화
echo "Disabling ntpdate-in-ns.timer..."
systemctl disable --now ntpdate-in-ns.timer >/dev/null 2>&1 || true

# 2) 신규 유닛 파일 삭제
rm -f "$SERVICE_FILE" "$TIMER_FILE"
echo "Removed service and timer files."

# 3) Systemd 리로드
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "== done =="
