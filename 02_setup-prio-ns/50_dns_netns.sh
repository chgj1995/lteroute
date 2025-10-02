#!/usr/bin/env bash
. "$(dirname "$0")/00_common.sh"; as_root; log setup "netns resolv.conf"

source .bearer_ipv4 || true
if [ -n "${DNS1:-}${DNS2:-}" ]; then
  mkdir -p "/etc/netns/${NS}"
  { [ -n "${DNS1:-}" ] && echo "nameserver ${DNS1}"; [ -n "${DNS2:-}" ] && echo "nameserver ${DNS2}"; } > "/etc/netns/${NS}/resolv.conf"
  log setup "/etc/netns/${NS}/resolv.conf 생성"
fi
