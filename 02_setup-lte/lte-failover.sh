#!/usr/bin/env bash
set -Eeuo pipefail

# ===== User-tunable =====
APN="${APN:-iot.1nce.net}"
IP_TYPE="${IP_TYPE:-ipv4}"

# ===== Binaries =====
IPBIN="/bin/ip"
MM="/usr/bin/mmcli"

log(){ echo "$(date '+%F %T') [lte-failover] $*" >&2; }
need_root(){ [ "$EUID" -eq 0 ] || { log "root 권한 필요 (sudo)"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- (1) LTE 연결 보장 + 검증 ----------
# 모뎀이 보일 때까지 대기
for _ in $(seq 1 40); do
  if $MM -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem/'; then break; fi
  sleep 0.5
done
MODEM_PATH="$($MM -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"

# 모뎀을 못 찾으면 실패로 종료 → systemd가 재시도
[ -n "$MODEM_PATH" ] || { log "No modem found (boot race). Exit 1 to retry"; exit 1; }
log "Modem: ${MODEM_PATH}"

pick_data_bearer() {
  local mp="$1" b BEARERS detail
  mapfile -t BEARERS < <($MM -m "$mp" 2>/dev/null | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+')
  for b in "${BEARERS[@]}"; do
    detail="$($MM -b "$b" 2>/dev/null)"
    echo "$detail" | grep -q 'connected:[[:space:]]*yes' || continue
    if echo "$detail" | grep -q 'IPv4 configuration' && echo "$detail" | grep -q 'address:'; then
      echo "$b"; return 0
    fi
  done
  return 1
}

verify_connection() {
  local iface="$1" gw="$2"
  local targets=("8.8.8.8" "1.1.1.1" "9.9.9.9") ok=1
  if [ -z "${gw}" ]; then
    log "WARN: Gateway is empty, verification skipped for ${iface}."
    return 1
  fi
  ip link set "${iface}" up || true
  ip route replace "${gw}" dev "${iface}" scope link proto static 2>/dev/null || true
  for target in "${targets[@]}"; do
    log "Verifying ${iface}: temp route ${target} via ${gw}"
    ip route replace "${target}/32" via "${gw}" dev "${iface}" proto static metric 50 2>/dev/null || true
    for _ in $(seq 1 3); do
      if ping -I "${iface}" -c 1 -W 3 "${target}" >/dev/null 2>&1; then ok=0; break; fi
      sleep 1
    done
    ip route del "${target}/32" via "${gw}" dev "${iface}" 2>/dev/null || true
    [ $ok -eq 0 ] && break
  done
  [ $ok -ne 0 ] && log "WARN: Connection verification failed on ${iface}."
  return $ok
}

need_root

MAX_RETRIES=2
IFACE=""; ADDR=""; PFX=""; GW=""; DNS1=""; DNS2=""
for i in $(seq 1 ${MAX_RETRIES}); do
  log "--- Attempt ${i}/${MAX_RETRIES} to establish and verify LTE connection ---"

  if ! $MM -m "$MODEM_PATH" | grep -q 'state:[[:space:]]*connected'; then
    log "Modem not connected. Running simple-connect..."
    if ! $MM -m "$MODEM_PATH" --simple-connect="apn=${APN},ip-type=${IP_TYPE}" >/dev/null; then
      log "WARN: simple-connect failed. Retrying..."; sleep 3; continue
    fi
    log "Polling for a connected data bearer..."
    for _ in $(seq 1 15); do
      FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
      [ -n "$FINAL_BEARER_PATH" ] && break
      sleep 1
    done
  else
    log "Modem already 'connected'."
    FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
  fi

  if [ -z "${FINAL_BEARER_PATH:-}" ]; then
    log "WARN: No usable (connected+IPv4) bearer. Retrying..."; sleep 3; continue
  fi
  log "Using data bearer: ${FINAL_BEARER_PATH}"

  DETAIL="$($MM -b "$FINAL_BEARER_PATH" 2>/dev/null || true)"
  IFACE="$(printf '%s\n' "$DETAIL" | sed -n 's/^[[:space:]]*|[[:space:]]*interface:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
  : "${IFACE:=wwan0}"
  BLK="$(printf '%s\n' "$DETAIL" | sed -n '/^  IPv4 configuration /,/^  --------------------------------/p')"
  ADDR="$(printf '%s\n' "$BLK" | sed -n 's/.*address:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
  PFX="$( printf '%s\n' "$BLK" | sed -n 's/.*prefix:[[:space:]]*\(.*\)$/\1/p'  | head -n1)"
  GW="$(  printf '%s\n' "$BLK" | sed -n 's/.*gateway:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
  MTU="$( printf '%s\n' "$BLK" | sed -n 's/.*mtu:[[:space:]]*\(.*\)$/\1/p'     | head -n1)"
  DNS1="$(printf '%s\n' "$BLK" | sed -n 's/.*dns:[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
  DNS2="$(printf '%s\n' "$BLK" | sed -n 's/.*dns:[[:space:]]*[0-9.]\+,[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
  log "Bearer IPv4: iface=${IFACE} ${ADDR}/${PFX} gw=${GW} dns=${DNS1},${DNS2}"

  if [ -z "${ADDR:-}" ] || [ -z "${GW:-}" ] || [ -z "${DNS1:-}" ]; then
    log "WARN: Incomplete IPv4 info. Retrying..."; sleep 3; continue
  fi

  # 인터페이스 up과 on-link GW 보장, IP 적용
  ${IPBIN} addr flush dev "${IFACE}" || true
  ${IPBIN} addr add "${ADDR}/${PFX}" dev "${IFACE}"
  ${IPBIN} link set "${IFACE}" up
  ${IPBIN} route replace "${GW}" dev "${IFACE}" scope link proto static || true

  # systemd-resolve를 통해 wwan0 인터페이스의 DNS 설정을 명시적으로 지정합니다.
  DNS_ARGS=""
  [ -n "${DNS1:-}" ] && DNS_ARGS="${DNS_ARGS} --set-dns=${DNS1}"
  [ -n "${DNS2:-}" ] && DNS_ARGS="${DNS_ARGS} --set-dns=${DNS2}"
  log "Applying DNS for ${IFACE} via systemd-resolve: ${DNS1} ${DNS2:-}"
  systemd-resolve --interface="${IFACE}" ${DNS_ARGS} --set-domain=~.

  if verify_connection "${IFACE}" "${GW}"; then
    log "--- LTE connection verified. Adding default route with high metric ---"
    # metric=3000 (이더넷보다 후순위)
    $IPBIN route replace default via "$GW" dev "$IFACE" proto static metric 3000
    break
  fi
  log "WARN: Verification failed. Will retry if attempts remain."
done

# 실패 시 systemd 재시도 유도
[ -n "${IFACE:-}" ] || { log "ERR: LTE connection not available."; exit 1; }

log "LTE failover route ready on ${IFACE}. Configuration finished."
echo "== ip route | grep ${IFACE} =="
$IPBIN route show | grep -F " dev $IFACE" || true
