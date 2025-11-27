#!/bin/bash

# reboot 관련 항목만 제거
(crontab -l 2>/dev/null | grep -v "/sbin/reboot") | crontab -

echo "🗑 자동 재부팅 설정이 제거되었습니다."
crontab -l