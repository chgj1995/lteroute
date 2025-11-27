#!/usr/bin/env bash
set -Eeuo pipefail

UNIT="/etc/systemd/system/turn-on-lte.service"

# 새 유닛 해제
sudo systemctl disable --now turn-on-lte.service >/dev/null 2>&1 || true
sudo rm -f "${UNIT}"

# 레거시 유닛이 남아있다면 같이 정리
sudo systemctl disable --now lte-gpio-power.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/lte-gpio-power.service
sudo systemctl disable --now lte-gpio-power-off.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/lte-gpio-power-off.service

sudo systemctl daemon-reload
echo "Removed: ${UNIT} (and any legacy LTE GPIO units if existed)"
