#!/usr/bin/env bash
set -Eeuo pipefail

# 환경변수로 보드에 맞게 덮어쓸 수 있습니다.
GPIOCHIP="${GPIOCHIP:-gpiochip4}"   # 예: gpiochip4
GPIO_OFFSET="${GPIO_OFFSET:-1}"      # 예: 1
VALUE_ON="${VALUE_ON:-1}"            # 켤 때 값
RETRIES="${RETRIES:-3}"              # 재시도 횟수
SLEEP_SEC="${SLEEP_SEC:-0.5}"        # 재시도 간격(초)

UNIT="/etc/systemd/system/turn-on-lte.service"
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"

if ! command -v gpioset >/dev/null 2>&1; then
  sudo apt-get install -y gpiod
fi

# 0) 과거/찌꺼기 제거(있으면)
sudo systemctl disable --now turn-on-lte.service >/dev/null 2>&1 || true
sudo rm -f "${UNIT}"
sudo rm -f "${WANTS_DIR}/turn-on-lte.service"
sudo systemctl disable --now lte-gpio-power.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/lte-gpio-power.service
sudo systemctl disable --now lte-gpio-power-off.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/lte-gpio-power-off.service

# 1) 유닛 파일 생성 (작은따옴표 heredoc으로 안전하게 기록)
sudo tee "${UNIT}" >/dev/null <<'EOF'
[Unit]
Description=Power on LTE module via GPIO
Before=ModemManager.service NetworkManager.service prio-ns-autoswitch.service tailscale-route-restore.service network-online.target
# gpiochip 디바이스가 있을 때만 실행
ConditionPathExists=/dev/gpiochip4

[Service]
Type=oneshot
# 실패 대비 3회 재시도
ExecStart=/bin/bash -lc 'for i in 1 2 3; do if /usr/bin/gpioset gpiochip4 1=1; then exit 0; fi; sleep 0.5; done; exit 1'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 2) systemd 반영 및 enable/start
sudo systemctl daemon-reload

if ! sudo systemctl enable --now turn-on-lte.service; then
  # enable 실패 시(Invalid argument 등) 우회 경로: link + add-wants
  sudo systemctl link "${UNIT}"
  sudo systemctl add-wants multi-user.target turn-on-lte.service
  sudo systemctl start turn-on-lte.service
fi

# 3) 상태 출력
sudo systemctl --no-pager status turn-on-lte.service || true
echo "Installed: ${UNIT}"
