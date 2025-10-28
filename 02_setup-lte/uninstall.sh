#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="lte-failover.service"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
BIN_DST="/usr/local/sbin/lte-failover.sh"

echo "[uninstall] 시작: 서비스 중지/삭제 → 바이너리 제거 순으로 진행합니다."

# (A) 서비스 정리
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo "[uninstall] 서비스 중지 중..."
  systemctl stop "${SERVICE_NAME}" || true
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}"; then
  echo "[uninstall] 서비스 비활성화 중..."
  systemctl disable "${SERVICE_NAME}" || true
fi

# ▼ 여기서 reset-failed 를 먼저 수행 (유닛이 아직 로드된 상태일 때)
echo "[uninstall] 실패 상태 리셋..."
systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

# ▼ 그 다음 유닛 파일 삭제 + 데몬 리로드
if [[ -f "${UNIT_PATH}" ]]; then
  echo "[uninstall] 유닛 파일 삭제: ${UNIT_PATH}"
  rm -f "${UNIT_PATH}"
else
  echo "[uninstall] 유닛 파일이 없습니다: ${UNIT_PATH}"
fi

echo "[uninstall] systemd 데몬 리로드..."
systemctl daemon-reload

# (B) 바이너리 및 설정 파일 제거
if [ -f "$BIN_DST" ]; then
  echo "[uninstall] 바이너리 삭제: $BIN_DST"
  rm -f "$BIN_DST"
fi

# (C) 구버전 PBR 설정 파일(.allow)이 있다면 삭제
if [ -f "/etc/lte_pbr.allow" ]; then
  echo "[uninstall] 구버전 PBR 설정 파일 삭제: /etc/lte_pbr.allow"
  rm -f "/etc/lte_pbr.allow"
fi

echo "[uninstall] 완료. 'ip route' 로 wwan 인터페이스의 기본 경로가 삭제되었는지 확인하세요."
