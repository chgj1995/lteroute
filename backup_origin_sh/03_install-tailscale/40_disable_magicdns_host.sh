#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

# 메인 네임스페이스에서 MagicDNS 주입 비활성(메모 그대로; 실패해도 계속)
if sudo tailscale set --accept-dns=false >/dev/null 2>&1; then
  echo "[info] MagicDNS disabled in host netns"
else
  echo "[info] host 'tailscale set --accept-dns=false' failed (socket missing?)"
  echo "       If needed, run inside prio_ns:"
  echo "         sudo ip netns exec prio_ns tailscale set --accept-dns=false"
fi
