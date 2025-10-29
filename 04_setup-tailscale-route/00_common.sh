#!/usr/bin/env bash
set -Eeuo pipefail

# ===== 로깅/유틸 =====
log(){ echo "$(date '+%F %T') [$1] ${2:-}" >&2; }
die(){ log "err" "$1"; exit 1; }
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root"; }

exists_link(){ ip link show "$1" >/dev/null 2>&1; }
ns_exists(){ ip netns list | grep -q "^${NS}\b"; }
ns_link_exists(){ ip netns exec "${NS}" ip link show "$1" >/dev/null 2>&1; }
ns_ip4_for(){ ip netns exec "${NS}" ip -o -4 addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -n1; }
host_ip4_for(){ ip -o -4 addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -n1; }

STATE_DIR="${STATE_DIR:-.state}"
mkdir -p "${STATE_DIR}"

# ===== 자동탐지 =====
detect_ns(){
  if [ -n "${NS:-}" ] && ip netns list | grep -q "^${NS}\b"; then
    :;
  elif ip netns list | grep -q "^prio_ns\b"; then
    NS="prio_ns"
  else
    local ncount; ncount="$(ip netns list | wc -l | tr -d ' ')"
    [ "$ncount" = "1" ] && NS="$(ip netns list | awk '{print $1}')" || die "네임스페이스 자동탐지 실패"
  fi
  log info "NS=${NS}"
}

detect_veth_pair(){
  if [ -n "${VETH_MAIN:-}" ] && [ -n "${VETH_NS:-}" ]; then
    exists_link "${VETH_MAIN}" || die "호스트 ${VETH_MAIN} 없음"
    ns_link_exists "${VETH_NS}" || die "NS ${VETH_NS} 없음"
    return
  fi
  local cand_main; cand_main="$(ip -o -4 addr show | awk '$4 ~ /^10\.254\.0\.1\/30$/ {print $2}' | head -n1)"
  [ -n "$cand_main" ] || cand_main="$(ip -o -4 addr show | awk '$2 ~ /^veth/ && $4 ~ /\/30$/ {print $2}' | head -n1)"
  [ -n "$cand_main" ] || die "호스트 veth 자동탐지 실패"
  VETH_MAIN="$cand_main"

  local cand_ns; cand_ns="$(ip netns exec "${NS}" ip -o -4 addr show | awk '$2 ~ /^veth/ && $4 ~ /^10\.254\.0\.[0-9]+\/30$/ {print $2}' | head -n1)"
  [ -n "$cand_ns" ] || cand_ns="$(ip netns exec "${NS}" ip -o -4 addr show | awk '$2 ~ /^veth/ && $4 ~ /\/30$/ {print $2}' | head -n1)"
  [ -n "$cand_ns" ] || die "NS veth 자동탐지 실패"
  VETH_NS="$cand_ns"

  log info "VETH_MAIN=${VETH_MAIN}, VETH_NS=${VETH_NS}"
}

detect_veth_ips(){
  local cidr
  cidr="$(host_ip4_for "${VETH_MAIN}")"; [ -n "$cidr" ] || die "호스트 ${VETH_MAIN} IPv4 없음"
  HOST_VETH_IP="${HOST_VETH_IP:-${cidr%/*}}"
  cidr="$(ns_ip4_for "${VETH_NS}")"; [ -n "$cidr" ] || die "NS ${VETH_NS} IPv4 없음"
  NS_VETH_IP="${NS_VETH_IP:-${cidr%/*}}"
  log info "HOST_VETH_IP=${HOST_VETH_IP}, NS_VETH_IP=${NS_VETH_IP}"
}

detect_ts_if(){
  if ns_link_exists "tailscale0"; then TS_IF="tailscale0"
  else TS_IF="$(ip netns exec "${NS}" ip -o link | awk -F': ' '$2 ~ /^tailscale[0-9]+$/ {print $2; exit}')"
  fi
  [ -n "${TS_IF:-}" ] || die "NS ${NS} tailscale 인터페이스 없음"
  log info "TS_IF=${TS_IF}"
}

detect_ts_cidr(){
  TS_CIDR="${TS_CIDR:-100.64.0.0/10}"  # 기본값
  local ipcidr ip4; ipcidr="$(ns_ip4_for "${TS_IF}")"; ip4="${ipcidr%/*}"
  if [ -n "${ip4}" ] && echo "$ip4" | grep -qE '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    :; else log info "TS_IF ${TS_IF}가 100.64/10 외처럼 보임 → TS_CIDR=${TS_CIDR} 사용"; fi
}

APP_PORTS="${APP_PORTS:-"3000 22"}"

# 실행 시 자동탐지
detect_ns
detect_veth_pair
detect_veth_ips
detect_ts_if
detect_ts_cidr

# 기록
{
  echo "NS=${NS}"
  echo "VETH_MAIN=${VETH_MAIN}"
  echo "VETH_NS=${VETH_NS}"
  echo "HOST_VETH_IP=${HOST_VETH_IP}"
  echo "NS_VETH_IP=${NS_VETH_IP}"
  echo "TS_IF=${TS_IF}"
  echo "TS_CIDR=${TS_CIDR}"
  echo "APP_PORTS='${APP_PORTS}'"
} > "${STATE_DIR}/detected_env"
log info "autodetect saved: ${STATE_DIR}/detected_env"

require_prio_ns(){ ns_exists || die "netns ${NS} 없음"; exists_link "${VETH_MAIN}" || die "host ${VETH_MAIN} 없음"; ns_link_exists "${VETH_NS}" || die "ns ${VETH_NS} 없음"; }
require_tailscale_in_ns(){ ns_link_exists "${TS_IF}" || die "ns ${NS}에 ${TS_IF} 없음"; }
