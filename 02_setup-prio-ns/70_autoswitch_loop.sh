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

host_route_ok=true # Assume route exists at start

check_iface() {  # $1 = IFACE in netns (VETH_NS)
  # 1. 호스트에 기본 인터넷 경로가 있는지 먼저 확인
  if ! ip route show default | grep -q '.*'; then
    if [ "$host_route_ok" = true ]; then
      log watch "Host default route not found. Assuming main connection is down."
      host_route_ok=false
    fi
    return 1
  fi

  # 호스트 경로가 복구되었으면 로그를 남김
  if [ "$host_route_ok" = false ]; then
    log watch "Host default route has been restored."
    host_route_ok=true
  fi

  # 2. 호스트 경로가 있다면, 실제 핑 테스트로 연결성 검증
  for h in "${CHECK_HOSTS[@]}"; do
    if ip netns exec "${NS}" ping -I "$1" -c1 -W1 "$h" >/dev/null 2>&1; then
      return 0
    fi
  done

  # 핑이 실패하면 nc로 2차 확인
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
  # onlink 경로에서 GW를 직접 추출
  ip netns exec "${NS}" ip -4 route show dev "${LTE_IF}" \
    | sed -n 's/default via \([0-9.]\+\) .*onlink.*/\1/p' \
    | head -n1
}

# -------- initial baseline in netns --------
# prio-ns-ensure.sh가 모든 네임스페이스, 인터페이스, 라우트(main/standby) 설정을 완료했다고 가정
log watch "Assuming prio-ns-ensure.sh has configured the network correctly."
log watch "Starting monitoring loop..."

# rp_filter relax (host) - ensure에서 했지만 여기서도 확인
set_host_rpf_relax

current="main"
main_fail=0
main_ok=0

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