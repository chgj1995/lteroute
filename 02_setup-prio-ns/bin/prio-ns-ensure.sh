#!/usr/bin/env bash
set -Eeuo pipefail

NS="prio_ns"
VETH_MAIN="veth-main"
VETH_NS="veth-ns"
HOST_IP="10.254.0.1/30"
NS_IP="10.254.0.2/30"

APN="${APN:-iot.1nce.net}"
IP_TYPE="${IP_TYPE:-ipv4}"

IPBIN="/bin/ip"
MM="/usr/bin/mmcli"

log(){ echo "$(date '+%F %T') [ensure] $*" >&2; }

# 0) prio_ns / veth 보장
$IPBIN netns list | grep -q "^${NS}\b" || $IPBIN netns add "${NS}"
$IPBIN link show "${VETH_MAIN}" >/dev/null 2>&1 || $IPBIN link add "${VETH_MAIN}" type veth peer name "${VETH_NS}"
$IPBIN link set "${VETH_NS}" netns "${NS}" 2>/dev/null || true
$IPBIN addr show dev "${VETH_MAIN}" | grep -q "${HOST_IP}" || $IPBIN addr add "${HOST_IP}" dev "${VETH_MAIN}" || true
$IPBIN link set "${VETH_MAIN}" up || true
$IPBIN netns exec "${NS}" bash -lc "
  ip addr show dev ${VETH_NS} | grep -q '${NS_IP}' || ip addr add ${NS_IP} dev ${VETH_NS} || true
  ip link set ${VETH_NS} up || true
  ip link set lo up || true
"

# 1) ModemManager가 모뎀을 인식할 때까지 대기(최대 20초)
for _ in $(seq 1 40); do
  if $MM -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem/'; then break; fi
  sleep 0.5
done
MODEM_PATH="$($MM -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"
[ -n "$MODEM_PATH" ] || { log "No modem found; skip LTE"; exit 0; }
log "Modem: ${MODEM_PATH}"

# --- Helper Functions ---
pick_data_bearer() {
  local mp="$1" b BEARERS detail
  mapfile -t BEARERS < <($MM -m "$mp" 2>/dev/null | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+')
  for b in "${BEARERS[@]}"; do
    detail="$($MM -b "$b" 2>/dev/null)"
    # 1. 연결되어 있는지 확인
    echo "$detail" | grep -q 'connected:[[:space:]]*yes' || continue
    # 2. IPv4 설정 블록과 주소가 있는지 확인 (가장 확실한 방법)
    if echo "$detail" | grep -q 'IPv4 configuration' && echo "$detail" | grep -q 'address:'; then
      echo "$b"; return 0
    fi
  done
  return 1
}

verify_connection() {
  local iface="$1"
  log "Verifying connection on interface ${iface} in netns ${NS}..."
  for _ in $(seq 1 3); do
    if ip netns exec "${NS}" ping -I "${iface}" -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
      log "Connection on ${iface} is VERIFIED."
      return 0
    fi
    sleep 1
  done
  log "WARN: Connection on ${iface} failed verification."
  return 1
}

# --- Main Connection Logic ---
MAX_RETRIES=2
for i in $(seq 1 ${MAX_RETRIES}); do
  log "--- Attempt ${i}/${MAX_RETRIES} to establish and verify LTE connection ---"

  # 1) 'simple-connect'를 사용하여 연결 보장
  if ! $MM -m "$MODEM_PATH" | grep -q 'state:[[:space:]]*connected'; then
    log "Modem not connected. Running simple-connect..."
    if ! $MM -m "$MODEM_PATH" --simple-connect="apn=${APN},ip-type=${IP_TYPE}" >/dev/null; then
      log "WARN: simple-connect command failed. Retrying..."
      sleep 3
      continue
    fi
    # 폴링 루프: 최대 15초간 '연결된 데이터 베어러'를 찾음
    log "simple-connect command issued. Polling for a connected data bearer..."
    for _ in $(seq 1 15); do
      FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
      if [ -n "$FINAL_BEARER_PATH" ]; then
        break
      fi
      sleep 1
    done
  else
    log "Modem already in 'connected' state."
    FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
  fi

  # 2) 최종적으로 사용 가능한 데이터 베어러 확인
  if [ -z "$FINAL_BEARER_PATH" ]; then
      log "WARN: Could not find a usable (connected + IPv4) bearer. Retrying..."
      sleep 3
      continue
  fi
  log "Using verified data bearer: ${FINAL_BEARER_PATH}"

  # 3) IPv4/IFACE 정보 파싱
  eval "$( $MM -b "$FINAL_BEARER_PATH" -K 2>/dev/null | awk -F= '
      $1=="bearer.interface"         { printf("IFACE=\"%s\"\n",$2) }
      $1=="bearer.ipv4.address"      { printf("ADDR=\"%s\"\n",$2) }
      $1=="bearer.ipv4.prefix"       { printf("PFX=\"%s\"\n",$2) }
      $1=="bearer.ipv4.gateway"      { printf("GW=\"%s\"\n",$2) }
      $1=="bearer.ipv4.mtu"          { printf("MTU=\"%s\"\n",$2) }
      $1=="bearer.ipv4.dns1"         { printf("DNS1=\"%s\"\n",$2) }
      $1=="bearer.ipv4.dns2"         { printf("DNS2=\"%s\"\n",$2) }
  ')"
  : "${IFACE:=wwan0}"
  log "Bearer: ${FINAL_BEARER_PATH} iface=${IFACE} ${ADDR}/${PFX} gw=${GW} dns=${DNS1},${DNS2}"

  if [ -z "${ADDR:-}" ] || [ -z "${GW:-}" ] || [ -z "${DNS1:-}" ]; then
    log "WARN: Incomplete network info from bearer. Retrying..."
    sleep 3
    continue
  fi

  # 4) 인터페이스를 NS로 이동 및 설정
  if $IPBIN link show "$IFACE" >/dev/null 2>&1; then
    $IPBIN link set "$IFACE" netns "$NS" 2>/dev/null || true
  fi
  $IPBIN netns exec "$NS" bash -lc "
    ip addr flush dev ${IFACE} || true
    ip addr add ${ADDR}/${PFX} dev ${IFACE}
    [ -n '${MTU:-}' ] && ip link set ${IFACE} mtu ${MTU}
    ip link set ${IFACE} up
    ip route replace default via ${GW} dev ${IFACE} metric 100 onlink
  "
  mkdir -p "/etc/netns/${NS}"
  { echo "nameserver ${DNS1}"; [ -n "${DNS2:-}" ] && echo "nameserver ${DNS2}"; } > "/etc/netns/${NS}/resolv.conf"
  log "Applied LTE IPv4 settings in ${NS}."

  # 5) 연결 검증
  if verify_connection "${IFACE}"; then
    log "--- LTE connection successfully established and verified. ---"
    exit 0 # 최종 성공
  fi
  log "WARN: Verification failed. Will retry if attempts remain."
done

log "err" "Failed to establish a verified LTE connection after ${MAX_RETRIES} attempts."
exit 1
