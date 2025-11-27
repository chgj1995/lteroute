#!/bin/bash

# 매일 12시에 재부팅하도록 크론 설정 (시간은 원하는 대로 변경 가능)
CRON_JOB="0 12 * * * /sbin/reboot"

# 기존에 같은 내용이 있으면 제거하고 다시 추가
(crontab -l 2>/dev/null | grep -v "/sbin/reboot"; echo "$CRON_JOB") | crontab -

echo "✅ 매일 새벽 4시에 자동 재부팅되도록 설정되었습니다."
crontab -l