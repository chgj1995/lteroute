#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

log failover "Monitoring loop started."

# -------- State variables --------
main_if=""
current_state="unknown" # unknown, main, lte
last_log_state="unknown"

# -------- Helper functions --------
check_connection() {
    local iface=$1
    for host in "${CHECK_HOSTS[@]}"; do
        if ping -c 1 -W 2 -I "$iface" "$host" &>/dev/null; then
            return 0 # 성공
        fi
    done
    return 1 # 실패
}

get_main_interface() {
    for iface in "${CHECK_OUT_IFS[@]}"; do
        if ip link show "$iface" up &>/dev/null; then
            echo "$iface"
            return
        fi
    done
}

# -------- Main loop --------
fail_count=0
recover_count=0

while true; do
    main_if=$(get_main_interface)

    if [ -z "$main_if" ]; then
        # 주 연결 인터페이스가 아예 없는 경우
        current_state="lte"
        if [ "$current_state" != "$last_log_state" ]; then
            log failover "Main interface not found. Ensuring LTE is primary."
            # LTE 연결을 재확인하여 metric 100의 경로를 보장
            bash "$(dirname "$0")/20_reconnect_lte.sh" || log failover "LTE reconnect script failed."
            last_log_state=$current_state
        fi
    else
        # 주 연결 인터페이스가 존재하는 경우
        if check_connection "$main_if"; then
            # 주 연결 정상
            recover_count=$((recover_count + 1))
            fail_count=0
            if [ "$recover_count" -ge "$RECOVER_THRESHOLD" ]; then
                current_state="main"
                if [ "$current_state" != "$last_log_state" ]; then
                    log failover "Main connection ($main_if) is healthy. Switching to main."
                    ip route replace default dev "$main_if" metric 10 2>/dev/null || true
                    # LTE는 이미 reconnect 스크립트에 의해 metric 100으로 설정되어 있음
                    last_log_state=$current_state
                fi
                recover_count=0
            fi
        else
            # 주 연결 실패
            fail_count=$((fail_count + 1))
            recover_count=0
            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
                current_state="lte"
                if [ "$current_state" != "$last_log_state" ]; then
                    log failover "Main connection ($main_if) failed. Switching to LTE."
                    # 1. LTE 인터페이스 바운스 및 경로 재설정 (metric 100)
                    bash "$(dirname "$0")/20_reconnect_lte.sh" || log failover "LTE reconnect script failed."
                    # 2. 주 연결의 metric을 높여 후순위로 만듦
                    ip route change default dev "$main_if" metric 200 2>/dev/null || true
                    last_log_state=$current_state
                fi
                fail_count=0
            fi
        fi
    fi

    sleep "$INTERVAL"
done
