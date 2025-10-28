#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

log lte-reconnect "Starting LTE connection/reconnection process..."

# 1) ModemManager가 모뎀을 인식할 때까지 대기(최대 20초)
for _ in $(seq 1 40); do
  if mmcli -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem/'; then break; fi
  sleep 0.5
done
MODEM_PATH="$(mmcli -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"
[ -n "$MODEM_PATH" ] || { log lte-reconnect "No modem found; skipping."; exit 0; }
log lte-reconnect "Modem: ${MODEM_PATH}"

# --- Helper Functions ---
pick_data_bearer() {
  local mp="$1" b BEARERS detail
  mapfile -t BEARERS < <(mmcli -m "$mp" 2>/dev/null | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+')
  for b in "${BEARERS[@]}"; do
    detail="$(mmcli -b "$b" 2>/dev/null)"
    if echo "$detail" | grep -q 'connected:[[:space:]]*yes' && \
       echo "$detail" | grep -q 'IPv4 configuration' && \
       echo "$detail" | grep -q 'address:'; then
      echo "$b"; return 0
    fi
  done
  return 1
}

verify_connection() {
  local iface="$1" gw="$2"
  local target="8.8.8.8" result=1
  [ -n "$gw" ] || { log lte-reconnect "WARN: Gateway empty, verification skipped."; return 1; }

  log lte-reconnect "Verifying connection on ${iface} via ${gw}..."
  for _ in $(seq 1 3); do
    if ping -c 1 -W 3 -I "${iface}" "${target}" >/dev/null 2>&1; then
      log lte-reconnect "Connection on ${iface} is VERIFIED."
      result=0
      break
    fi
    sleep 1
  done
  [ "$result" -eq 0 ] || log lte-reconnect "WARN: Connection on ${iface} failed verification."
  return $result
}

# --- Main Connection Logic (Replicated from prio-ns-ensure.sh) ---
MAX_RETRIES=2
for i in $(seq 1 ${MAX_RETRIES}); do
  log lte-reconnect "--- Attempt ${i}/${MAX_RETRIES} ---"

  # 1) 모뎀 전체 상태('state') 확인 (기존 로직 복원)
  MODEM_STATUS_OUTPUT="$(mmcli -m "$MODEM_PATH")"
  if ! echo "$MODEM_STATUS_OUTPUT" | grep -q 'state:[[:space:]]*connected'; then
    log lte-reconnect "Modem not in 'connected' state. Attempting simple-connect..."
    # 'TooMany' 오류 방지를 위해 에러 출력 무시
    if ! mmcli -m "$MODEM_PATH" --simple-connect="apn=${APN}" >/dev/null 2>&1; then
      log lte-reconnect "simple-connect command failed or modem already connecting. Polling for bearer..."
    fi
    # 폴링 루프: 'simple-connect' 요청 후, 완전히 준비된 베어러를 기다림 (핵심 로직)
    log lte-reconnect "Polling for a connected data bearer for up to 15s..."
    FINAL_BEARER_PATH=""
    for _ in $(seq 1 15); do
      FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
      [ -n "$FINAL_BEARER_PATH" ] && break
      sleep 1
    done
  else
    log lte-reconnect "Modem already in 'connected' state. Picking existing bearer."
    FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
  fi

  # 2) 최종 베어러 확인
  if [ -z "$FINAL_BEARER_PATH" ]; then
      log lte-reconnect "WARN: Could not find a usable bearer. Retrying..."
      sleep 3; continue
  fi
  log lte-reconnect "Using data bearer: ${FINAL_BEARER_PATH}"

  # 3) IPv4/IFACE 정보 파싱
  DETAIL="$(mmcli -b "$FINAL_BEARER_PATH")"
  IFACE="$(printf '%s\n' "$DETAIL" | sed -n 's/.*interface:[[:space:]]*\([^ ]\+\).*/\1/p' | head -n1)"
  : "${IFACE:=${LTE_IF:-wwan0}}"

  BLK="$(printf '%s\n' "$DETAIL" | sed -n '/^  IPv4 configuration /,/^  --------------------------------/p')"
  ADDR="$(printf '%s\n' "$BLK" | sed -n 's/.*address:[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
  PFX="$( printf '%s\n' "$BLK" | sed -n 's/.*prefix:[[:space:]]*\([0-9]\+\).*/\1/p'  | head -n1)"
  GW="$(  printf '%s\n' "$BLK" | sed -n 's/.*gateway:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
  MTU="$( printf '%s\n' "$BLK" | sed -n 's/.*mtu:[[:space:]]*\(.*\)$/\1/p'     | head -n1)"
  DNS_LIST="$(printf '%s\n' "$BLK" | sed -n 's/.*dns:[[:space:]]*\([0-9.,[:space:]]\+\).*/\1/p' | head -n1 | tr -d ' ' | tr ',' ' ')"
  read -r DNS1 DNS2 <<< "$DNS_LIST"

  log lte-reconnect "Bearer info: iface=${IFACE} ${ADDR}/${PFX} gw=${GW} dns=${DNS1},${DNS2}"
  if [ -z "${ADDR:-}" ] || [ -z "${GW:-}" ]; then
    log lte-reconnect "WARN: Incomplete network info. Retrying..."
    sleep 3; continue
  fi

  # 4) 인터페이스가 생성될 때까지 대기 (경쟁 상태 방지)
  log lte-reconnect "Waiting for interface ${IFACE} to appear..."
  for _ in $(seq 1 20); do
    if ip link show "${IFACE}" >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  if ! ip link show "${IFACE}" >/dev/null 2>&1; then
    log lte-reconnect "err" "Interface ${IFACE} did not appear in time. Retrying..."
    sleep 3; continue
  fi
  log lte-reconnect "Interface ${IFACE} found."

  # 5) 인터페이스 설정 (메인 네임스페이스)
  ip link set "${IFACE}" down 2>/dev/null || true
  ip addr flush dev "${IFACE}" 2>/dev/null || true
  ip addr add "${ADDR}/${PFX}" dev "${IFACE}"
  [ -n "${MTU:-}" ] && ip link set "${IFACE}" mtu "${MTU}"
  ip link set "${IFACE}" up

  # 6) 라우팅 설정 (후순위 metric)
  log lte-reconnect "Adding standby default route via ${GW} with metric 100"
  ip route replace default via "${GW}" dev "${IFACE}" metric 100 onlink

  # 7) DNS 라우팅 설정
  if [ -n "${DNS1:-}" ]; then
    log lte-reconnect "Adding routes for DNS servers ${DNS1}, ${DNS2}"
    ip route add "${DNS1}/32" via "${GW}" >/dev/null 2>&1 || true
    [ -n "${DNS2:-}" ] && ip route add "${DNS2}/32" via "${GW}" >/dev/null 2>&1 || true
  fi

  log lte-reconnect "Applied LTE IPv4 settings in main namespace."

  # 8) 연결 검증
  if verify_connection "${IFACE}" "${GW}"; then
    log lte-reconnect "--- LTE connection successfully established. ---"
    exit 0 # 최종 성공
  fi
  log lte-reconnect "WARN: Verification failed. Will retry if attempts remain."
done

log "err" "Failed to establish a verified LTE connection after ${MAX_RETRIES} attempts."
exit 1
