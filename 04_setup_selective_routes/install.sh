#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== selective-routes install =="

# --- 설정 파일 및 스크립트 복사 ---
echo "==> installing files..."
install -d -m 0755 /etc/prio-ns
install -m 0644 "${DIR}/selective_routes.conf" /etc/prio-ns/
echo "  - /etc/prio-ns/selective_routes.conf copied"

install -d -m 0755 /usr/local/sbin
install -m 0755 "${DIR}/manage_selective_routes.sh" /usr/local/sbin/
echo "  - /usr/local/sbin/manage_selective_routes.sh copied"

# --- 기존 systemd 서비스 정리 ---
OLD_UNIT="selective-routes.service"
if systemctl list-unit-files | grep -q "$OLD_UNIT"; then
    echo "==> removing old ${OLD_UNIT}"
    systemctl disable --now "$OLD_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${OLD_UNIT}"
    systemctl daemon-reload
fi

# --- 나머지 설정 스크립트 실행 (기반 설정) ---
# manage_selective_routes.sh는 autoswitch에 의해 호출되므로 여기서는 실행하지 않음
run(){ local f="$1"; echo "==> $(basename "$f")"; bash "$f"; }
steps=(10_ns_rpf.sh 20_nat_forward.sh 30_nat_forward_wwan.sh 40_dnat_app.sh)
for f in "${steps[@]}"; do run "$DIR/$f"; done

echo "== done =="
