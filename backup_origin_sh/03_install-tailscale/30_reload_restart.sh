#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root
sudo systemctl daemon-reload
sudo systemctl enable --now tailscaled || true
sudo systemctl restart tailscaled || true
