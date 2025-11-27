#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

ok=0
for i in $(seq 1 10); do
  if ip netns exec "${NS}" ip link show tailscale0 >/dev/null 2>&1; then
    echo "$(date '+%F %T') [setup] tailscale0 up (in ${NS})"
    ok=1
    break
  fi
  sleep 1
done

if [ "$ok" -ne 1 ]; then
  echo "$(date '+%F %T') [info] tailscale0 not visible yet. If not logged-in:"
  echo "  sudo ip netns exec ${NS} tailscale up --authkey=<YOUR_KEY> --hostname=$(hostname)-ns"
fi
