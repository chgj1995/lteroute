#!/usr/bin/env bash
set -Eeuo pipefail

# ---- 기본 설정 (환경변수로 덮어쓰기 가능) ----
LTE_IF="${LTE_IF:-wwan0}"
APN="${APN:-iot.1nce.net}"
CHECK_OUT_IFS=(${CHECK_OUT_IFS:-eth0 wlan0})

CHECK_HOSTS=(${CHECK_HOSTS:-8.8.8.8 1.1.1.1})
INTERVAL="${INTERVAL:-3}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
RECOVER_THRESHOLD="${RECOVER_THRESHOLD:-2}"
LTE_BOUNCE_SEC="${LTE_BOUNCE_SEC:-2}"

log(){ echo "$(date '+%F %T') [$1] ${2:-}" >&2; }
die(){ log "err" "$1"; exit 1; }
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root"; }

exists_link(){ ip link show "$1" >/dev/null 2>&1; }

# mmcli helpers
get_modem_path(){ mmcli -L | awk '/ModemManager1\/Modem/ {print $1; exit}' || true; }
get_bearer_path(){ local m="$1"; mmcli -m "$m" | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+' | tail -n1 || true; }
