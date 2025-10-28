#!/usr/bin/env bash
set -Eeuo pipefail

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }; }
need_root

echo "== lte-failover uninstall =="

# 1) 서비스 중지 및 비활성화
systemctl disable --now lte-failover.service >/dev/null 2>&1 || true

# 2) 유닛 파일 제거 후 리로드
rm -f /etc/systemd/system/lte-failover.service
systemctl daemon-reload

# 3) 이전 버전의 prio-ns 서비스도 제거 (하위 호환성)
systemctl disable --now prio-ns-autoswitch.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/prio-ns-autoswitch.service
rm -f /usr/local/sbin/prio-ns-ensure.sh

echo "== done =="
