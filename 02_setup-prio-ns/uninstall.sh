#!/usr/bin/env bash
set -Eeuo pipefail

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }; }
need_root

echo "== setup prio-ns uninstall =="

# 서비스 정지 및 비활성화(마스크 사용 안 함)
systemctl disable --now prio-ns-autoswitch.service >/dev/null 2>&1 || true

# 유닛 제거 후 reload
rm -f /etc/systemd/system/prio-ns-autoswitch.service
systemctl daemon-reload

# ensure 스크립트 제거
rm -f /usr/local/sbin/prio-ns-ensure.sh

# 네임스페이스/링크는 운영 정책에 따라 유지. 필요하면 아래 주석 해제:
# ip netns del prio_ns >/dev/null 2>&1 || true
# ip link del veth-main >/dev/null 2>&1 || true

echo "== done =="
