#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== tailscale-route install =="

run(){ local f="$1"; echo "==> $(basename "$f")"; bash "$f"; }

steps=(10_host_ts_route.sh 20_ns_rpf.sh 30_nat_forward.sh 35_nat_forward_wwan.sh 40_dnat_app.sh 50_save_state.sh)
for f in "${steps[@]}"; do run "$DIR/$f"; done

# 부팅 복원용 systemd (이전 ts-route 유닛을 대체)
install -d "$DIR/systemd"
UNIT="/etc/systemd/system/tailscale-route-restore.service"
cat > "$UNIT" <<EOF
[Unit]
Description=Restore Tailscale route/NAT in netns at boot
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${DIR}
ExecStart=/usr/bin/env bash ${DIR}/60_restore_state.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable --now tailscale-route-restore.service
systemctl --no-pager status tailscale-route-restore.service || true

echo "== done =="
