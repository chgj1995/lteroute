#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }; }
need_root

echo "== setup prio-ns install =="

# 1) 단계 스크립트 실행(존재할 때만) - 설치 시점에만 필요
run_glob() {
  local step="$1" matched=0 f
  for f in "$DIR/${step}_"*.sh; do
    [ -e "$f" ] || continue
    matched=1
    echo "==> $(basename "$f")"
    bash "$f"
  done
  [ "$matched" -eq 1 ] || echo "-- skip: ${step}_*.sh 없음"
}
# 10(ns/veth 생성), 60(호스트 NAT)만 실행
for s in 10 60; do run_glob "$s"; done

# 2) ensure 및 prepare 스크립트 배포
install -D -m 0755 "$DIR/bin/prio-ns-ensure.sh" /usr/local/sbin/prio-ns-ensure.sh
install -D -m 0755 "$DIR/bin/prepare-prio-ns.sh" /usr/local/sbin/prepare-prio-ns.sh
sed -i 's/\r$//' /usr/local/sbin/prio-ns-ensure.sh /usr/local/sbin/prepare-prio-ns.sh
sed -i '1s/^\xEF\xBB\xBF//' /usr/local/sbin/prio-ns-ensure.sh /usr/local/sbin/prepare-prio-ns.sh

# 3) autoswitch 유닛(마스크 해제 → 재배포 → enable --now)
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
ExecStartPre=/usr/local/sbin/prepare-prio-ns.sh "${DIR}"
ExecStart=/usr/bin/env bash ${DIR}/70_autoswitch_loop.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable --now prio-ns-autoswitch.service

echo "== done =="