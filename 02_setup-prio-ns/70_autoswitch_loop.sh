#!/usr/bin/env bash
set -Eeuo pipefail

# -------- load common --------
. "$(dirname "$0")/00_common.sh"

as_root
log watch "autoswitch start"

# -------- consts/paths --------
MANAGE_ROUTES_SCRIPT="/usr/local/sbin/manage_selective_routes.sh"

# -------- helpers --------
check_iface() {
    # ... (기존 check_iface 함수 내용과 동일)
    if ! ip route show default | grep -q '.*'; then
        if [ "${host_route_ok}" = true ]; then
            log watch "Host default route not found. Assuming main connection is down."
            host_route_ok=false
        fi
        return 1
    fi
    if [ "${host_route_ok}" = false ]; then
        log watch "Host default route is back. Resuming main connection check."
        host_route_ok=true
    fi
    for h in "${CHECK_HOSTS[@]}"; do
        if ip netns exec "${NS}" ping -I "$1" -c1 -W1 "$h" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

get_lte_gw() {
    # ... (기존 get_lte_gw 함수 내용과 동일)
    local MODEM_PATH BEARER_PATH DETAIL BLK
    MODEM_PATH="$(mmcli -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"
    if [ -z "$MODEM_PATH" ]; then return 1; fi
    BEARER_PATH="$(pick_data_bearer "$MODEM_PATH")"
    if [ -z "$BEARER_PATH" ]; then return 1; fi
    DETAIL="$(mmcli -b "$BEARER_PATH" 2>/dev/null || true)"
    BLK="$(printf '%s\n' "$DETAIL" | sed -n '/^  IPv4 configuration /,/^  --------------------------------/p')"
    printf '%s\n' "$BLK" | sed -n 's/.*gateway:[[:space:]]*\(.*\)$/\1/p' | head -n1
}

# (이외 필요한 pick_data_bearer 등 다른 helper 함수들은 여기에 그대로 존재한다고 가정)
pick_data_bearer() {
  local mp="$1" b BEARERS detail
  mapfile -t BEARERS < <(mmcli -m "$mp" 2>/dev/null | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+')
  for b in "${BEARERS[@]}"; do
    detail="$(mmcli -b "$b" 2>/dev/null)"
    if echo "$detail" | grep -q 'connected:[[:space:]]*yes' && echo "$detail" | grep -q 'IPv4 configuration' && echo "$detail" | grep -q 'address:'; then
      echo "$b"; return 0
    fi
  done
  return 1
}

# -------- main loop --------
log watch "Starting monitoring loop..."

# 시작 시 혹시 모를 잔여 경로 정리
if [ -f "$MANAGE_ROUTES_SCRIPT" ]; then
    log watch "Initial cleanup of selective routes..."
    bash "$MANAGE_ROUTES_SCRIPT" down
fi

current="main"
main_fail=0
main_ok=0
host_route_ok=true

trap '
  log watch "stop -> cleaning up routes"
  if [ -f "$MANAGE_ROUTES_SCRIPT" ]; then
    bash "$MANAGE_ROUTES_SCRIPT" down
  fi
  # prio_ns 내부 경로도 원래대로 복원
  ip netns exec "'"${NS}"'" ip route replace default via "'"${HOST_VETH_IP}"'" dev "'"${VETH_NS}"'" metric 10 || true
  exit 0
' INT TERM

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
        ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 10 || true
        ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 100 || true

        # --- 메인 네임스페이스 경로 추가 ---
        if [ -f "$MANAGE_ROUTES_SCRIPT" ]; then
            log watch "Applying selective routes for main namespace..."
            bash "$MANAGE_ROUTES_SCRIPT" up
        fi

        current="lte"
        main_fail=0
        main_ok=0
        log watch "NS DEFAULT -> LTE"
      else
        log watch "WARN: LTE GW not found. Cannot switch."
      fi
    fi
  else # current=lte
    if [ "${main_ok}" -ge "${RECOVER_THRESHOLD}" ]; then
      log watch "MAIN recovered -> switching back to MAIN"
      ip netns exec "${NS}" ip route replace default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10 || true
      LTE_GW="$(get_lte_gw)"
      if [ -n "${LTE_GW}" ]; then
        ip netns exec "${NS}" ip route replace default via "${LTE_GW}" dev "${LTE_IF}" onlink metric 100 || true
      fi

      # --- 메인 네임스페이스 경로 삭제 ---
      if [ -f "$MANAGE_ROUTES_SCRIPT" ]; then
          log watch "Removing selective routes from main namespace..."
          bash "$MANAGE_ROUTES_SCRIPT" down
      fi

      current="main"
      main_fail=0
      main_ok=0
      log watch "NS DEFAULT -> MAIN (LTE standby)"
    fi
  fi

  sleep "${INTERVAL}"
done
