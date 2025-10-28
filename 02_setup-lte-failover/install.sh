#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }; }
need_root

echo "== setup lte-failover install =="

# 1) 기존 prio-ns 관련 서비스 중지 및 비활성화
systemctl disable --now prio-ns-autoswitch.service >/dev/null 2>&1 || true

# 2) LTE 초기 연결 실행 (실패하더라도 서비스 등록은 계속 진행)
echo "==> Running 20_reconnect_lte.sh for initial setup"
bash "$DIR/20_reconnect_lte.sh" || true

# 3) failover 서비스 유닛 재배포 및 시작
UNIT="/etc/systemd/system/lte-failover.service"
systemctl unmask lte-failover.service >/dev/null 2>&1 || true
cat >"$UNIT" <<EOF
[Unit]
Description=LTE Failover Service (main <-> LTE)
After=turn-on-lte.service ModemManager.service network-online.target
Wants=network-online.target ModemManager.service
Before=tailscaled.service

[Service]
Type=simple
WorkingDirectory=${DIR}
ExecStartPre=-/usr/bin/env bash ${DIR}/20_reconnect_lte.sh
ExecStart=/usr/bin/env bash ${DIR}/70_autoswitch_loop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable --now lte-failover.service

echo "== done =="
