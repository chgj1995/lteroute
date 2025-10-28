#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== selective-routes install =="

# 설정 파일 복사
install -d -m 0755 /etc/prio-ns
install -m 0644 "${DIR}/selective_routes.conf" /etc/prio-ns/
echo "  - /etc/prio-ns/selective_routes.conf copied"

run(){ local f="$1"; echo "==> $(basename "$f")"; bash "$f"; }

# 실행할 스크립트 목록 정의
steps=(10_host_ts_route.sh 20_ns_rpf.sh 30_nat_forward.sh 35_nat_forward_wwan.sh 40_dnat_app.sh)
for f in "${steps[@]}"; do run "$DIR/$f"; done

# --- systemd 서비스 재구성 ---
OLD_UNIT="tailscale-route-restore.service"
if systemctl list-unit-files | grep -q "$OLD_UNIT"; then
    echo "==> removing old ${OLD_UNIT}"
    systemctl disable --now "$OLD_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${OLD_UNIT}"
fi

NEW_UNIT="/etc/systemd/system/selective-routes.service"
echo "==> installing systemd service: ${NEW_UNIT}"

EXEC_COMMANDS=""
for f in "${steps[@]}"; do
    EXEC_COMMANDS+="/usr/bin/env bash ${DIR}/$f && "
done
EXEC_COMMANDS=${EXEC_COMMANDS%** && }

cat > "$NEW_UNIT" <<EOF
[Unit]
Description=Apply selective routes for prio_ns from config file at boot
After=network-online.target tailscaled.service prio-ns-setup.service
Wants=network-online.target
BindsTo=tailscaled.service prio-ns-setup.service

[Service]
Type=oneshot
WorkingDirectory=${DIR}
ExecStart=/bin/sh -c "${EXEC_COMMANDS}"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$NEW_UNIT"
systemctl daemon-reload
systemctl enable --now selective-routes.service
systemctl --no-pager status selective-routes.service || true

echo "== done =="
