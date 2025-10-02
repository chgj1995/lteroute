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

ensure_lte_connected() {
  log watch "Ensuring LTE modem is connected..."
  local MODEM_PATH
  MODEM_PATH="$(mmcli -L | awk '/ModemManager1\/Modem/ {print $1; exit}' || true)"
  if [ -z "${MODEM_PATH}" ]; then
    log watch "WARN: No modem found by mmcli."
    return 1
  fi

  if ! mmcli -m "${MODEM_PATH}" | grep -q 'state:[[:space:]]*connected'; then
    log watch "Modem not connected. Attempting simple-connect..."
    if ! mmcli -m "${MODEM_PATH}" --simple-connect="apn=${APN},ip-type=ipv4" >/dev/null; then
       log watch "WARN: simple-connect command failed."
       return 1
    fi
    log watch "Connection command sent. Waiting for connected state..."
    # 연결 상태가 될 때까지 잠시 대기 (최대 15초)
    for _ in $(seq 1 15); do
      if mmcli -m "${MODEM_PATH}" | grep -q 'state:[[:space:]]*connected'; then
        log watch "Modem is now connected."
        # 연결 후 route가 생길 시간을 조금 더 줌
        sleep 3
        return 0
      fi
      sleep 1
    done
    log watch "WARN: Modem did not reach connected state."
    return 1
  fi
  log watch "Modem is already connected."
  return 0
}

bounce_lte_and_restore_standby() {
  # LTE 링크 리프레시 (세션 끊기)
  log watch "Bouncing LTE link (${LTE_IF}) to refresh session"
  ip netns exec "${NS}" ip link set "${LTE_IF}" down 2>/dev/null || true
  sleep "${LTE_BOUNCE_SEC}"
  ip netns exec "${NS}" ip link set "${LTE_IF}" up 2>/dev/null || true

  # 연결 재시도 및 standby 라우트(메트릭 높게)
  ensure_lte_connected || true
  local LTE_GW
  for _ in $(seq 1 5); do
    LTE_GW="$(get_lte_gw)"
    [ -n "${LTE_GW}" ] && break
    sleep 1
  done

  if [ -n "${LTE_GW}" ]; then
    ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 100 || true
    log watch "LTE standby route restored (via ${LTE_GW})"
  else
    log watch "WARN: could not find LTE GW to restore standby route"
  fi
}

# -------- initial baseline in netns --------
# prio-ns-ensure.sh가 남긴 초기 상태를 그대로 사용
# host<->ns point-to-point (veth)
ip netns exec "${NS}" ip route replace "${HOST_VETH_IP}/32" dev "${VETH_NS}" || true

# rp_filter relax (host/netns) - ensure에서 했지만 여기서도 확인
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

# LTE standby 미리 준비 (prio-ns-ensure.sh가 실패했을 경우 대비)
log watch "Initial check for LTE standby route..."
ensure_lte_connected || true
LTE_GW_INIT="$(get_lte_gw)"
if [ -n "${LTE_GW_INIT}" ]; then
  ip netns exec "${NS}" ip route replace default via "${LTE_GW_INIT}" dev "${LTE_IF}" onlink metric 100 || true
  log watch "LTE standby route ensured (via ${LTE_GW_INIT})"
else
  log watch "WARN: Initial LTE standby route could not be set."
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
      # LTE 연결 보장 및 GW 확인
      ensure_lte_connected || true
      LTE_GW="$(get_lte_gw)"
      if [ -n "${LTE_GW}" ]; then
        # netns default -> LTE
        ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 10 || true
        # netns default -> MAIN(veth)은 standby로
        ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 100 || true
        # host default -> veth-main (외부로 나가는 길을 ns로)
        switch_host_default_to_ns
        current="lte"
        main_fail=0
        main_ok=0
        log watch "DEFAULT -> LTE (host+ns)"
      else
        log watch "LTE GW missing; staying on MAIN"
      fi
    fi
  else # current=lte
    if [ "${main_ok}" -ge "${RECOVER_THRESHOLD}" ]; then
      log watch "MAIN recovered -> cutover to MAIN and bounce LTE"
      # netns default -> MAIN(veth)
      ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10 || true
      # host default 복구
      restore_host_default
      # LTE standby (세션 끊고 재접속 후 standby 라우트 설정)
      bounce_lte_and_restore_standby
      current="main"
      main_fail=0
      main_ok=0
      log watch "DEFAULT -> MAIN (LTE standby)"
    fi
  fi

  sleep "${INTERVAL}"
done
