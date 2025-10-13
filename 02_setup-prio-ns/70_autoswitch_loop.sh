#!/usr/bin/env bash
set -Eeuo pipefail

# -------- load common --------
#  - NS, VETH_NS, VETH_MAIN, HOST_VETH_IP, LTE_IF
#  - CHECK_HOSTS, INTERVAL, FAIL_THRESHOLD, RECOVER_THRESHOLD, LTE_BOUNCE_SEC
#  - log(), as_root(), exists_link() 등
. "$(dirname "$0")/00_common.sh"

as_root
log watch "autoswitch start"

# -------- consts/paths --------
STATE_DIR="/run/prio-ns"
HOST_DEF_BAK="${STATE_DIR}/host_default.bak"

mkdir -p "${STATE_DIR}"

# -------- helpers --------
flush_cache() {
  ip -4 route flush cache 2>/dev/null || true
}

backup_host_default() {
  ip -4 route show default > "${HOST_DEF_BAK}" 2>/dev/null || true
}

restore_host_default() {
  if [ -s "${HOST_DEF_BAK}" ]; then
    # veth-main default 제거
    ip -4 route del default dev "${VETH_MAIN}" 2>/dev/null || true
    # 백업 복구
    while read -r line; do
      # 복구 시 동일 prefix는 replace
      ip -4 route replace ${line}
    done < "${HOST_DEF_BAK}"
    rm -f "${HOST_DEF_BAK}"
    flush_cache
    log watch "HOST default restored"
  fi
}

del_non_veth_defaults() {
  # veth-main 이외의 default 경로들을 모두 제거 (충돌 방지)
  # grep을 사용하면 대상이 없을 때 0이 아닌 값을 반환하여 'set -e'에 의해 스크립트가 종료될 수 있음.
  # 따라서 한 줄씩 읽어 처리하는 견고한 while 루프 사용.
  local line
  ip -4 route show default | while read -r line; do
    # 라인에서 'dev' 뒤의 디바이스 이름을 추출
    local dev
    dev=$(echo "$line" | sed -n 's/.* dev \([^ ]\+\).*/\1/p')
    # 디바이스 이름이 veth-main이 아니면 해당 경로 삭제
    if [[ -n "$dev" && "$dev" != "${VETH_MAIN}" ]]; then
      log watch "Removing conflicting default route: $line"
      ip -4 route del $line 2>/dev/null || true
    fi
  done
}

switch_host_default_to_ns() {
  log watch "HOST default -> veth-main (${HOST_VETH_IP%/*} peer: ${NS})"
  backup_host_default
  del_non_veth_defaults
  # veth-main 경유 default를 낮은 metric으로 지정
  ip -4 route replace default via "${HOST_VETH_IP%/*}" dev "${VETH_MAIN}" metric 5
  flush_cache
}

set_host_rpf_relax() {
  sysctl -w net.ipv4.conf."${VETH_MAIN}".rp_filter=2 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.all.rp_filter=2          >/dev/null 2>&1 || true
}

# prio-ns-ensure.sh와 동일한 로직을 사용하여 현재 연결된 데이터 베어러를 찾음
pick_data_bearer() {
  local mp="$1" b BEARERS detail
  mapfile -t BEARERS < <(mmcli -m "$mp" 2>/dev/null | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+')
  for b in "${BEARERS[@]}"; do
    detail="$(mmcli -b "$b" 2>/dev/null)"
    # 1. 연결되어 있는지 확인
    echo "$detail" | grep -q 'connected:[[:space:]]*yes' || continue
    # 2. IPv4 설정 블록과 주소가 있는지 확인 (가장 확실한 방법)
    if echo "$detail" | grep -q 'IPv4 configuration' && echo "$detail" | grep -q 'address:'; then
      echo "$b"; return 0
    fi
  done
  return 1
}

check_iface() {  # $1 = IFACE in netns (VETH_NS)
  # 1. 호스트에 기본 인터넷 경로가 있는지 먼저 확인
  # 호스트의 주 연결(예: 이더넷 DHCP)이 설정되기 전까지는 prio_ns를 통한 ping이 의미 없음.
  if ! ip route show default | grep -q '.*'; then
    if [ "${host_route_ok}" = true ]; then
      log watch "Host default route not found. Assuming main connection is down."
      host_route_ok=false
    fi
    return 1
  fi
  # 호스트 경로가 다시 생긴 경우 로그를 남김
  if [ "${host_route_ok}" = false ]; then
    log watch "Host default route is back. Resuming main connection check."
    host_route_ok=true
  fi

  # 2. prio_ns 내부에서 실제 인터넷 연결 확인 (ping/nc)
  for h in "${CHECK_HOSTS[@]}"; do
    if ip netns exec "${NS}" ping -I "$1" -c1 -W1 "$h" >/dev/null 2>&1; then
      return 0
    fi
  done
  if command -v nc >/dev/null 2>&1; then
    for h in "${CHECK_HOSTS[@]}"; do
      if ip netns exec "${NS}" bash -lc "printf '' | timeout 2 nc -vz -I $1 $h 80" >/dev/null 2>&1; then
        return 0
      fi
    done
  fi
  return 1
}

get_lte_gw() {
  # [중요] OS 라우팅 테이블이 아닌, ModemManager(진실의 원천)에서 직접 GW 정보를 가져옴.
  # 이는 외부 요인(NetworkManager 등)에 의해 라우팅 정보가 변경되더라도 안정적으로 GW를 찾기 위함.
  local MODEM_PATH BEARER_PATH DETAIL BLK
  MODEM_PATH="$(mmcli -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"
  if [ -z "$MODEM_PATH" ]; then
    log watch "WARN: No modem found by get_lte_gw."
    return 1
  fi

  BEARER_PATH="$(pick_data_bearer "$MODEM_PATH")"
  if [ -z "$BEARER_PATH" ]; then
    log watch "WARN: No active data bearer found by get_lte_gw."
    return 1
  fi

  DETAIL="$(mmcli -b "$BEARER_PATH" 2>/dev/null || true)"
  BLK="$(printf '%s\n' "$DETAIL" | sed -n '/^  IPv4 configuration /,/^  --------------------------------/p')"
  printf '%s\n' "$BLK" | sed -n 's/.*gateway:[[:space:]]*\(.*\)$/\1/p' | head -n1
}

# -------- initial baseline in netns --------
# prio-ns-ensure.sh가 모든 네임스페이스, 인터페이스, 라우트(main/standby) 설정을 완료했다고 가정
log watch "Assuming prio-ns-ensure.sh has configured the network correctly."

# [중요] veth 인터페이스(main)는 물리적 연결 상태와 무관하게 항상 'UP' 상태를 유지합니다.
# 따라서, 커널의 metric 기반 자동 경로 전환이 동작하지 않습니다.
# 이 스크립트는 주기적으로 주 경로(veth-ns)의 실제 인터넷 연결을 'check_iface' 함수로
# 능동적으로 확인하고, 실패 시에만 동적으로 라우팅 테이블을 변경하여 LTE로 전환합니다.
log watch "Starting monitoring loop..."

# rp_filter relax (host) - ensure에서 했지만 여기서도 확인
set_host_rpf_relax

current="main"
main_fail=0
main_ok=0
host_route_ok=true # 호스트 기본 경로 상태 추적 변수

trap '
  log watch "stop -> restore NS default"
  # restore_host_default
  ip netns exec "'"${NS}"'" ip route replace default via "'"${HOST_VETH_IP}"'" dev "'"${VETH_NS}"'" metric 10 || true
  exit 0
' INT TERM

# -------- main loop --------
while true; do
  if check_iface "${VETH_NS}"; then
    main_fail=0
    main_ok=$((main_ok+1))
  else
    main_fail=$((main_fail+1))
    main_ok=0
  fi

  if [ "${current}" = "main" ]; then
    if [ "${main_fail}" -ge "${FAIL_THRESHOLD}" ]; then
      log watch "MAIN unhealthy -> switching to LTE"
      LTE_GW="$(get_lte_gw)"
      if [ -n "${LTE_GW}" ]; then
        # NS default: LTE 우선 (metric 10)
        ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 10 || true
        # NS default: MAIN은 대기 (metric 100)
        ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 100 || true
        # Host default 변경은 비활성화
        # switch_host_default_to_ns
        current="lte"
        main_fail=0
        main_ok=0
        log watch "NS DEFAULT -> LTE"
      else
        # 이 경고는 prio-ns-ensure.sh가 실패했음을 의미
        log watch "WARN: LTE GW not found. Cannot switch."
      fi
    fi
  else # current=lte
    if [ "${main_ok}" -ge "${RECOVER_THRESHOLD}" ]; then
      log watch "MAIN recovered -> switching back to MAIN"
      # NS default: MAIN 우선 (metric 10)
      ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10 || true
      # NS default: LTE는 대기 (metric 100)
      LTE_GW="$(get_lte_gw)"
      if [ -n "${LTE_GW}" ]; then
        ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 100 || true
      fi
      # Host default 복구 비활성화
      # restore_host_default
      current="main"
      main_fail=0
      main_ok=0
      log watch "NS DEFAULT -> MAIN (LTE standby)"
    fi
  fi

  sleep "${INTERVAL}"
done