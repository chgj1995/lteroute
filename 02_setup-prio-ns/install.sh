#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }; }
need_root

echo "== setup prio-ns install =="

# 1) 스크립트 실행 권한 부여
chmod +x "$DIR"/bin/*.sh
chmod +x "$DIR"/*.sh

# 2) autoswitch 유닛(마스크 해제 → 재배포 → enable --now)
UNIT="/etc/systemd/system/prio-ns-autoswitch.service"
systemctl unmask prio-ns-autoswitch.service >/dev/null 2>&1 || true
cat >"$UNIT" <<EOF
[Unit]
Description=prio_ns default route autoswitch (main <-> LTE)
After=network-online.target ModemManager.service tailscale-route-restore.service
Wants=network-online.target ModemManager.service

[Service]
Type=simple
WorkingDirectory=${DIR}
ExecStartPre=bash bin/prepare-prio-ns.sh
ExecStart=bash 70_autoswitch_loop.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable --now prio-ns-autoswitch.service

echo "== done =="