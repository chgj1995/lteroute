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
  # veth-main 이외의 default 들을 모두 제거(충돌 방지)
  ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1)}}' \
    | grep -v -E "^${VETH_MAIN}\$" | while read -r dev; do
        ip -4 route show default dev "${dev}" | while read -r _ _ gw _; do
          ip -4 route del default via "${gw}" dev "${dev}" 2>/dev/null || true
        done
      done
}

switch_host_default_to_ns() {
  log watch "HOST default -> veth-main (${HOST_VETH_IP} peer: ${NS})"
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

check_iface() {  # $1 = IFACE in netns (VETH_NS or ${LTE_IF})
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
  log watch "stop -> restore HOST default and NS default"
  restore_host_default
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
        # Host default -> veth-main (외부로 나가는 길을 ns로)
        switch_host_default_to_ns
        current="lte"
        main_fail=0
        main_ok=0
        log watch "DEFAULT -> LTE (host+ns)"
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
      # Host default 복구
      restore_host_default
      current="main"
      main_fail=0
      main_ok=0
      log watch "DEFAULT -> MAIN (LTE standby)"
    fi
  fi

  sleep "${INTERVAL}"
done
