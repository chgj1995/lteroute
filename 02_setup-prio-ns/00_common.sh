#!/usr/bin/env bash
set -Eeuo pipefail

# ---- 기본 설정 (환경변수로 덮어쓰기 가능) ----
NS="${NS:-prio_ns}"
LTE_IF="${LTE_IF:-wwan0}"
APN="${APN:-iot.1nce.net}"
VETH_MAIN="${VETH_MAIN:-veth-main}"
VETH_NS="${VETH_NS:-veth-ns}"
MAIN_IP_CIDR="${MAIN_IP_CIDR:-10.254.0.1/30}"
NS_IP_CIDR="${NS_IP_CIDR:-10.254.0.2/30}"
HOST_VETH_IP="${HOST_VETH_IP:-${MAIN_IP_CIDR%/*}}"
CHECK_OUT_IFS=(${CHECK_OUT_IFS:-eth0 wlan0 wwan0})

CHECK_HOSTS=(${CHECK_HOSTS:-8.8.8.8 1.1.1.1})
INTERVAL="${INTERVAL:-3}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
RECOVER_THRESHOLD="${RECOVER_THRESHOLD:-2}"
LTE_BOUNCE_SEC="${LTE_BOUNCE_SEC:-2}"

log(){ echo "$(date '+%F %T') [$1] ${2:-}" >&2; }
die(){ log "err" "$1"; exit 1; }
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root"; }

exists_link(){ ip link show "$1" >/dev/null 2>&1; }
ns_exists(){ ip netns list | grep -q "^${NS}\b"; }
ns_link_exists(){ ip netns exec "${NS}" ip link show "$1" >/dev/null 2>&1; }

# mmcli helpers
get_modem_path(){ mmcli -L | awk '/ModemManager1\/Modem/ {print $1; exit}' || true; }
get_bearer_path(){ local m="$1"; mmcli -m "$m" | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+' | tail -n1 || true; }

# stdout: "ADDR PFX GW MTU DNS1 DNS2"
parse_bearer_ipv4(){
  local b="$1"
  # IPv4 configuration 블록만 추출
  local blk
  blk="$(LC_ALL=C mmcli -b "$b" 2>/dev/null \
        | sed -n '/^  IPv4 configuration[[:space:]]*|/,/^  --------------------------------/p')"

  # 각 필드 파싱
  local a p g m dlist d1 d2
  a="$(echo "$blk" | sed -n 's/.*address:[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
  p="$(echo "$blk" | sed -n 's/.*prefix:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)"
  g="$(echo "$blk" | sed -n 's/.*gateway:[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
  m="$(echo "$blk" | sed -n 's/.*mtu:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)"
  dlist="$(echo "$blk" | sed -n 's/.*dns:[[:space:]]*\([0-9.,[:space:]]\+\).*/\1/p' | head -n1 \
           | tr -d ' ' | tr ',' ' ')"

  set -- $dlist
  d1="${1:-}"; d2="${2:-}"

  echo "${a:-} ${p:-} ${g:-} ${m:-} ${d1:-} ${d2:-}"
}

