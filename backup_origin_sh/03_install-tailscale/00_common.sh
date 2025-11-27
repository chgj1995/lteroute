#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo "$(date '+%F %T') [$1] ${2:-}" >&2; }
die(){ log "err" "$1"; exit 1; }
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root"; }

# 네임스페이스는 고정(prio_ns) – 메모에 맞춤
NS="prio_ns"
