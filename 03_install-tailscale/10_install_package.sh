#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

# tailscale이 이미 있으면 그대로 통과 (패키지 설치는 선택)
if ! command -v tailscaled >/dev/null 2>&1; then
  log info "tailscale not found; installing (apt)"
  . /etc/os-release || true
  codename="${VERSION_CODENAME:-bionic}"
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
    | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y tailscale
else
  log info "tailscale already installed"
fi

# EnvironmentFile 기본 생성(없다면)
[ -f /etc/default/tailscaled ] || sudo tee /etc/default/tailscaled >/dev/null <<'EOF'
# Environment for tailscaled (sourced by systemd unit)
# PORT=41641
# FLAGS=
EOF
