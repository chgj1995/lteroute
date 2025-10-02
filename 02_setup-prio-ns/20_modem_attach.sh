#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

APN="${APN:-iot.1nce.net}"
IP_TYPE="${IP_TYPE:-ipv4}"

NS="prio_ns"
IPBIN="/bin/ip"
MM="/usr/bin/mmcli"

log(){ echo "$(date '+%F %T') [attach] $*" >&2; }

# 0) netns/veth은 여기서 만들지 않음(10_ns_create.sh의 역할)

# 1) 모뎀 탐색 (최대 20초 대기)
for _ in $(seq 1 40); do
  if $MM -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem/'; then break; fi
  sleep 0.5
done

MODEM_PATH="$($MM -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"
[ -n "$MODEM_PATH" ] || { log "No modem found; skip"; exit 0; }
MODEM_IDX="$(echo "$MODEM_PATH" | sed 's#.*/##')"
log "Modem: ${MODEM_PATH} (idx ${MODEM_IDX})"

# 2) 연결 시도 (이미 connected면 통과) — 구버전은 인덱스로만 신뢰 가능
if ! $MM -m "$MODEM_IDX" 2>/dev/null | grep -q 'state:[[:space:]]*connected'; then
  log "simple-connect APN=${APN}, ip-type=${IP_TYPE}"
  $MM -m "$MODEM_IDX" --simple-connect="apn=${APN},ip-type=${IP_TYPE}" >/dev/null 2>&1 || true
fi

# 3) 베어러 나열 (구버전 호환: -K/--list-bearers 미사용)
#    사람읽기 출력에서 Bearer 경로만 뽑고, 각 bearer 상세를 살펴 IPv4 구성이 있는 놈을 선택
pick_ipv4_bearer() {
  local out bearers b detail blk
  out="$($MM -m "$MODEM_IDX" 2>/dev/null || true)"
  # 출력에 나오는 Bearer 경로들 추출
  bearers="$(printf '%s\n' "$out" | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+' | sort -u)"
  for b in $bearers; do
    detail="$($MM -b "$b" 2>/dev/null || true)"
    echo "$detail" | grep -q 'connected:[[:space:]]*yes' || continue
    blk="$(printf '%s\n' "$detail" | sed -n '/^  IPv4 configuration /,/^  --------------------------------/p')"
    [ -n "$blk" ] || continue
    # IPv4 method/주소가 있는지 확인
    if printf '%s\n' "$blk" | grep -q 'method:'; then
      echo "$b"
      return 0
    fi
  done
  return 1
}

BEARER_PATH=""
# simple-connect 후 네트워크가 자리잡을 시간 폴링(최대 30초)
for _ in $(seq 1 30); do
  BEARER_PATH="$(pick_ipv4_bearer || true)"
  [ -n "$BEARER_PATH" ] && break
  sleep 1
done

if [ -z "$BEARER_PATH" ]; then
  log "No usable bearer (connected+IPv4) after wait; leaving for autoswitch loop"
  # autoswitch가 재시도할 수 있도록 빈 파일만 남기고 종료
  : > .bearer_ipv4
  chmod 0644 .bearer_ipv4
  exit 0
fi

# 4) 선택된 bearer에서 IPv4 정보 파싱 (구버전 호환 sed)
DETAIL="$($MM -b "$BEARER_PATH" 2>/dev/null || true)"
IFACE="$(printf '%s\n' "$DETAIL" | sed -n 's/^[[:space:]]*|[[:space:]]*interface:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
[ -n "$IFACE" ] || IFACE="wwan0"

BLK="$(printf '%s\n' "$DETAIL" | sed -n '/^  IPv4 configuration /,/^  --------------------------------/p')"
ADDR="$(printf '%s\n' "$BLK" | sed -n 's/.*address:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
PFX="$( printf '%s\n' "$BLK" | sed -n 's/.*prefix:[[:space:]]*\(.*\)$/\1/p'  | head -n1)"
GW="$(  printf '%s\n' "$BLK" | sed -n 's/.*gateway:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
MTU="$( printf '%s\n' "$BLK" | sed -n 's/.*mtu:[[:space:]]*\(.*\)$/\1/p'     | head -n1)"
# DNS는 "dns: A, B" 형식
DNS1="$(printf '%s\n' "$BLK" | sed -n 's/.*dns:[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
DNS2="$(printf '%s\n' "$BLK" | sed -n 's/.*dns:[[:space:]]*[0-9.]\+,[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"

log "Bearer: ${BEARER_PATH} iface=${IFACE} ${ADDR:-?}/${PFX:-?} gw=${GW:-?} mtu=${MTU:-?}"

# 5) autoswitch가 사용할 IPv4 매개변수 저장 (이 스크립트는 netns 이동/라우팅은 하지 않음)
cat > .bearer_ipv4 <<EOF
ADDR=${ADDR:-}
PFX=${PFX:-}
GW=${GW:-}
MTU=${MTU:-}
DNS1=${DNS1:-}
DNS2=${DNS2:-}
LTE_IF=${IFACE}
EOF
chmod 0644 .bearer_ipv4
log "Wrote ./.bearer_ipv4 for autoswitch"
exit 0
