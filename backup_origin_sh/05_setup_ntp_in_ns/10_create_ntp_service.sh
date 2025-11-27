#!/usr/bin/env bash
set -Eeuo pipefail

as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
as_root

echo "== create ntpdate-in-ns.service and timer =="

SERVICE_FILE="/etc/systemd/system/ntpdate-in-ns.service"
TIMER_FILE="/etc/systemd/system/ntpdate-in-ns.timer"
NTP_SERVER="ntp.ubuntu.com"
NTPDATE_PATH=$(which ntpdate)

# 1) .service 파일 생성
tee "$SERVICE_FILE" >/dev/null <<UNIT
[Unit]
Description=Time synchronization using ntpdate in prio_ns
After=prio-ns-autoswitch.service
Wants=prio-ns-autoswitch.service

[Service]
Type=oneshot
ExecStart=/bin/ip netns exec prio_ns $NTPDATE_PATH -4 -s $NTP_SERVER
UNIT

# 2) .timer 파일 생성 (매 시간 실행)
tee "$TIMER_FILE" >/dev/null <<UNIT
[Unit]
Description=Run ntpdate-in-ns.service hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
UNIT

echo "Service and timer files created."
