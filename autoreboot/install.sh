#!/bin/bash
set -Eeuo pipefail

# root 권한 확인
if [[ $EUID -ne 0 ]]; then
  echo "이 스크립트는 root로 실행해야 합니다. (예: sudo bash install.sh)"
  exit 1
fi

CRON_JOB="0 12 * * * /sbin/reboot"

# root의 crontab에서 /sbin/reboot 라인을 제거한 뒤 새 일정 추가
( crontab -u root -l 2>/dev/null | grep -v "/sbin/reboot" ; echo "$CRON_JOB" ) | crontab -u root -

echo "✅ 매일 12:00(정오)에 자동 재부팅되도록 root 크론에 설정했습니다."
crontab -u root -l
