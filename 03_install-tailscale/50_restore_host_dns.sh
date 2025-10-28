#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

# 메인 네임스페이스 DNS 원복 (메모 그대로)
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
