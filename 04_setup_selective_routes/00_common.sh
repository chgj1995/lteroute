#!/usr/bin/env bash
set -Eeuo pipefail

# ---- 기본 설정 (02_setup-rio-ns와 일치시켜야 함) ----
NS="${NS:-prio_ns}"
VETH_MAIN="${VETH_MAIN:-veth-main}"
VETH_NS="${VETH_NS:-veth-ns}"
MAIN_IP_CIDR="${MAIN_IP_CIDR:-10.254.0.1/30}"
NS_IP_CIDR="${NS_IP_CIDR:-10.254.0.2/30}"
HOST_VETH_IP="${HOST_VETH_IP:-${MAIN_IP_CIDR%/*}}"
NS_VETH_IP="${NS_VETH_IP:-${NS_IP_CIDR%/*}}"
TS_IF="${TS_IF:-tailscale0}"
APP_PORT="${APP_PORT:-22}" # <--- 추가된 변수

# --- helpers ---
log(){ echo "$(date '+%F %T') [$1] ${2:-}" >&2; }
die(){ log "err" "$1"; exit 1; }
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root"; }

ns_exists(){ ip netns list | grep -q "^${NS}\b"; }
require_prio_ns(){ ns_exists || die "네임스페이스 자동탐지 실패"; }
