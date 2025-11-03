#!/bin/bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "이 스크립트는 root로 실행해야 합니다. (예: sudo bash uninstall.sh)"
  exit 1
fi

( crontab -u root -l 2>/dev/null | grep -v "/sbin/reboot" ) | crontab -u root -

echo "🗑 root 크론의 자동 재부팅 설정을 제거했습니다."
crontab -u root -l
