#!/usr/bin/env bash
set -Eeuo pipefail

# ===== paths / names =====
UNIT_NAME="lte-failover.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
BIN_DST="/usr/local/sbin/lte-failover.sh"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_BIN="${SRC_DIR}/lte-failover.sh"

log() { echo "[install] $*" >&2; }
need_root() { [ "$EUID" -eq 0 ] || { echo "root 권한 필요 (sudo로 실행)"; exit 1; }; }

need_root

# 0) 전제 확인
command -v systemctl >/dev/null || { echo "systemctl 필요"; exit 1; }
[ -f "${SRC_BIN}" ] || { echo "없음: ${SRC_BIN}"; exit 1; }

# 1) 바이너리 배치
install -d -m 0755 /usr/local/sbin
install -m 0755 "${SRC_BIN}" "${BIN_DST}"
log "배치됨: ${BIN_DST}"

# 2) systemd 유닛 작성
#  - 네트워크가 '진짜' 올라오고(ModemManager/NM 구성 후) 실행되도록 After/Wants 보강
#  - Type=simple + Restart=on-failure (oneshot + Restart 금지 이슈 회피)
cat > "${UNIT_PATH}" <<'EOF'
[Unit]
Description=Setup LTE failover route with high metric
After=network-online.target NetworkManager.service NetworkManager-wait-online.service ModemManager.service
Wants=network-online.target NetworkManager-wait-online.service ModemManager.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/lte-failover.sh
Restart=on-failure
RestartSec=8

[Install]
WantedBy=multi-user.target
EOF

log "유닛 생성: ${UNIT_PATH}"

# 4) 보조 유닛(있으면) 활성화: wait-online / ModemManager / NetworkManager
#    - 일부 배포판에는 없을 수 있으므로 실패해도 무시
systemctl enable --now NetworkManager.service 2>/dev/null || true
systemctl enable --now NetworkManager-wait-online.service 2>/dev/null || true
systemctl enable --now ModemManager.service 2>/dev/null || true

# 5) systemd 반영 및 서비스 활성화/시작
systemctl daemon-reload
systemctl enable "${UNIT_NAME}"
systemctl restart "${UNIT_NAME}"

log "설치 완료: ${UNIT_NAME}"
log "상태 확인: systemctl status ${UNIT_NAME} --no-pager"
log "로그 보기 : journalctl -b -u ${UNIT_NAME} --no-pager -n 200"
log "라우트확인: ip route | grep -F ' dev wwan' || true"
