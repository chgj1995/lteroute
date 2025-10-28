#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="lte-ensure.service"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
ADDED_LIST="/run/lte-pbr.dest"
IPBIN="/bin/ip"

echo "[uninstall] 시작: 라우트 정리 → 서비스 제거 순서로 진행합니다."

# (A) 라우트 제거
if [ -s "$ADDED_LIST" ]; then
  echo "[uninstall] 허용 라우트 제거 중..."
  tac "$ADDED_LIST" | while read -r dst; do
    if [[ "$dst" == */* ]]; then
      $IPBIN route del "$dst" 2>/dev/null || true
    else
      $IPBIN route del "${dst}/32" 2>/dev/null || true
    fi
  done
  rm -f "$ADDED_LIST"
  echo "[uninstall] 라우트 제거 완료."
else
  echo "[uninstall] 제거할 라우트 목록이 없습니다: $ADDED_LIST"
fi

# (B) 서비스 정리
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

echo "[uninstall] 완료. 필요 시 'ip route' 로 잔여 라우트 여부를 확인하세요."
