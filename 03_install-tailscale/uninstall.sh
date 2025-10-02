#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

sudo rm -f /etc/systemd/system/tailscaled.service.d/override.conf
sudo rmdir /etc/systemd/system/tailscaled.service.d 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl restart tailscaled || true
echo "Removed tailscaled override; daemon back to host netns."
