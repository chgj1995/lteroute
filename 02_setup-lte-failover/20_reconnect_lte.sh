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

# --- Helper Functions from prio-ns-ensure.sh ---
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

# --- Main Connection Logic from prio-ns-ensure.sh ---
MAX_RETRIES=2
for i in $(seq 1 ${MAX_RETRIES}); do
  log lte-reconnect "--- Attempt ${i}/${MAX_RETRIES} ---"

  # 1) 먼저 사용 가능한 데이터 베어러가 있는지 확인 (가장 안정적인 방법)
  FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"

  # 2) 베어러가 없을 때만 'simple-connect' 실행
  if [ -z "$FINAL_BEARER_PATH" ]; then
    log lte-reconnect "No active bearer found. Running simple-connect..."
    if ! mmcli -m "$MODEM_PATH" --simple-connect="apn=${APN}" >/dev/null; then
      log lte-reconnect "WARN: simple-connect failed. Retrying..."
      sleep 3; continue
    fi
    log lte-reconnect "Polling for a connected data bearer..."
    for _ in $(seq 1 15); do
      FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
      [ -n "$FINAL_BEARER_PATH" ] && break
      sleep 1
    done
  else
      log lte-reconnect "Found active bearer without new connection."
  fi

  # 3) 최종 베어러 확인
  if [ -z "$FINAL_BEARER_PATH" ]; then
      log lte-reconnect "WARN: Could not find a usable bearer after connect attempt. Retrying..."
      sleep 3; continue
  fi
  log lte-reconnect "Using data bearer: ${FINAL_BEARER_PATH}"

  # 4) IPv4/IFACE 정보 파싱 (호환성 보장)
  read -r ADDR PFX GW MTU DNS1 DNS2 < <(parse_bearer_ipv4 "$FINAL_BEARER_PATH")
  IFACE="${LTE_IF}"

  log lte-reconnect "Bearer info: iface=${IFACE} ${ADDR}/${PFX} gw=${GW} dns=${DNS1},${DNS2}"
  if [ -z "${ADDR:-}" ] || [ -z "${GW:-}" ] || [ -z "${DNS1:-}" ]; then
    log lte-reconnect "WARN: Incomplete network info from bearer. Retrying..."
    sleep 3; continue
  fi

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
  log lte-reconnect "Adding routes for DNS servers ${DNS1}, ${DNS2}"
  ip route add "${DNS1}/32" via "${GW}" >/dev/null 2>&1 || true
  [ -n "${DNS2:-}" ] && ip route add "${DNS2}/32" via "${GW}" >/dev/null 2>&1 || true

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
