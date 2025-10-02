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

ensure_lte_connected_and_routes() {
  # 베어러 파일(.bearer_ipv4)이 없다면 모뎀 attach 시도
  if [ ! -f .bearer_ipv4 ]; then
    bash "$(dirname "$0")/20_modem_attach.sh" || true
  fi
  # 파라미터 로드
  ADDR=""; PFX=""; GW=""; MTU=""; DNS1=""; DNS2=""
  if [ -f .bearer_ipv4 ]; then
    # shellcheck disable=SC1091
    . ./.bearer_ipv4 || true
  fi
  # 부족하면 한 번 더 시도
  if [ -z "${ADDR:-}" ] || [ -z "${PFX:-}" ] || [ -z "${GW:-}" ]; then
    bash "$(dirname "$0")/20_modem_attach.sh" || true
    # shellcheck disable=SC1091
    . ./.bearer_ipv4 || true
  fi

  # LTE 인터페이스를 NS로 이동/업
  if exists_link "${LTE_IF}"; then
    ip link set "${LTE_IF}" netns "${NS}" 2>/dev/null || true
  fi
  ip netns exec "${NS}" ip link set "${LTE_IF}" up 2>/dev/null || true

  # 주소/MTU 적용
  if [ -n "${ADDR:-}" ] && [ -n "${PFX:-}" ]; then
    ip netns exec "${NS}" ip addr flush dev "${LTE_IF}" || true
    ip netns exec "${NS}" ip addr add "${ADDR}/${PFX}" dev "${LTE_IF}" || true
  fi
  if [ -n "${MTU:-}" ]; then
    ip netns exec "${NS}" ip link set "${LTE_IF}" mtu "${MTU}" || true
  fi

  # rp_filter relax in netns
  ip netns exec "${NS}" sh -c '
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
    sysctl -w net.ipv4.conf.'"${LTE_IF}"'.rp_filter=2 >/dev/null
  ' || true

  # 게이트웨이 반환
  if [ -n "${GW:-}" ]; then
    echo "${GW}"
  fi
}

bounce_lte_and_restore_standby() {
  # LTE 링크 리프레시
  ip netns exec "${NS}" ip link set "${LTE_IF}" down 2>/dev/null || true
  sleep "${LTE_BOUNCE_SEC}"
  ip netns exec "${NS}" ip link set "${LTE_IF}" up 2>/dev/null || true

  # standby 라우트(메트릭 높게)
  if [ -f .bearer_ipv4 ]; then
    # shellcheck disable=SC1091
    . ./.bearer_ipv4 || true
  fi
  if [ -n "${GW:-}" ]; then
    ip netns exec "${NS}" ip route replace "${GW}" dev "${LTE_IF}" || true
    ip netns exec "${NS}" ip route replace default via "${GW}" dev "${LTE_IF}" onlink metric 100 || true
  fi
}

# -------- initial baseline in netns --------
# host<->ns point dst
ip netns exec "${NS}" ip route replace "${HOST_VETH_IP}/32" dev "${VETH_NS}" || true

# rp_filter relax (host/netns)
set_host_rpf_relax
ip netns exec "${NS}" sh -c '
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
' || true

# 기본값: MAIN 경로(호스트로) 우선
ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10 || true

current="main"
main_fail=0
main_ok=0

trap '
  log watch "stop -> restore HOST default and NS default"
  restore_host_default
  ip netns exec "'"${NS}"'" ip route replace default via "'"${HOST_VETH_IP}"'" dev "'"${VETH_NS}"'" metric 10 || true
  exit 0
' INT TERM

# LTE standby 미리 준비
LTE_GW="$(ensure_lte_connected_and_routes 2>/dev/null || true)"
if [ -n "${LTE_GW}" ]; then
  ip netns exec "${NS}" ip route replace "${LTE_GW}" dev "${LTE_IF}" || true
  ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 100 || true
fi

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
      log watch "MAIN unhealthy -> switch to LTE"
      LTE_GW="$(ensure_lte_connected_and_routes 2>/dev/null || true)"
      if [ -n "${LTE_GW}" ]; then
        # netns default -> LTE
        ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 10 || true
        ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 100 || true
        # host default -> veth-main
        switch_host_default_to_ns
        current="lte"
        main_fail=0
        main_ok=0
        log watch "DEFAULT -> LTE (host+ns)"
      else
        log watch "LTE GW missing; staying on MAIN"
      fi
    fi
  else
    if [ "${main_ok}" -ge "${RECOVER_THRESHOLD}" ]; then
      log watch "MAIN recovered -> cutover to MAIN and bounce LTE"
      # netns default -> HOST
      ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10 || true
      ip netns exec "${NS}" ip route del default dev "${LTE_IF}" 2>/dev/null || true
      # host default 복구
      restore_host_default
      # LTE standby
      bounce_lte_and_restore_standby
      current="main"
      main_fail=0
      main_ok=0
      log watch "DEFAULT -> MAIN (LTE standby)"
    fi
  fi

  sleep "${INTERVAL}"
done
