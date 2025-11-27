#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

sudo mkdir -p /etc/systemd/system/tailscaled.service.d
sudo tee /etc/systemd/system/tailscaled.service.d/override.conf >/dev/null <<'EOF'
[Unit]
# prio_ns가 먼저 준비된 뒤 시작 (oneshot 없이 의존만)
After=turn-on-lte.service prio-ns-autoswitch.service
Requires=prio-ns-autoswitch.service

[Service]
# 원 유닛의 EnvironmentFile(/etc/default/tailscaled) 그대로 사용
EnvironmentFile=/etc/default/tailscaled

# (중요) prio_ns가 실제로 보일 때까지 잠깐 대기 (최대 10초)
ExecStartPre=/bin/bash -lc 'for i in {1..20}; do ip netns list | grep -q "^prio_ns\\b" && exit 0; sleep 0.5; done; echo "prio_ns not ready"; exit 1'

# ExecStart 재정의(원 줄 제거 후 새 줄로 대체)
ExecStart=
ExecStart=/bin/ip netns exec prio_ns /usr/sbin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/run/tailscale/tailscaled.sock \
  --port=${PORT} $FLAGS

# 정리도 netns에서
ExecStopPost=
ExecStopPost=/bin/ip netns exec prio_ns /usr/sbin/tailscaled --cleanup
EOF
