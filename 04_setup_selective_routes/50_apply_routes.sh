#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

CONF_FILE="$(dirname "$0")/selective_routes.conf"
COPIED_CONF_FILE="/etc/prio-ns/selective_routes.conf"

if [ -f "$COPIED_CONF_FILE" ]; then
    CONF_FILE="$COPIED_CONF_FILE"
fi

log setup "선별적 경로 적용 (${CONF_FILE})"
require_prio_ns

if ! ip netns exec "${NS}" ip route show default | grep -q .; then
    log setup "WARN: prio_ns에 기본 경로가 없어 추가합니다. (via ${HOST_VETH_IP})"
    ip netns exec "${NS}" ip route add default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10
fi

get_clean_entry() {
    local line="$1"
    local entry_no_comment
    entry_no_comment=$(echo "$line" | sed 's/#.*//')
    local trimmed_entry
    trimmed_entry=$(echo "$entry_no_comment" | xargs)

    if [[ -n "$trimmed_entry" ]]; then
        echo "$trimmed_entry"
    fi
}

resolve_entry() {
    local entry="$1"
    ip netns exec "${NS}" getent ahosts "$entry" | awk '{print $1; exit}'
}

log setup "1단계: DNS 서버 설정 및 경로 추가"
DNS_SERVERS=()
while read -r line; do
    entry=$(get_clean_entry "$line")
    if [ -n "$entry" ]; then
        log setup "  - DNS서버 ${entry} 경로 추가"
        ip route replace "$entry" via "${NS_VETH_IP}" dev "${VETH_MAIN}"
        DNS_SERVERS+=("$entry")
    fi
done < <(sed -n '/\[dns_servers\]/,/\[.*\]/p' "$CONF_FILE" | grep -v '\[.*\]')

if [ ${#DNS_SERVERS[@]} -gt 0 ]; then
    log setup "  - prio_ns에 DNS 서버 설정 적용: ${DNS_SERVERS[*]}"
    mkdir -p "/etc/netns/${NS}"
    (printf "nameserver %s\n" "${DNS_SERVERS[@]}") | tee "/etc/netns/${NS}/resolv.conf" > /dev/null
else
    log setup "WARN: 설정 파일에 DNS 서버가 없습니다. 도메인 이름 해석이 실패할 수 있습니다."
fi

log setup "2단계: 나머지 경로 설정"
while read -r line; do
    entry=$(get_clean_entry "$line")
    if [ -n "$entry" ]; then
        if [[ ! "$entry" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
            log setup "  - ${entry} resolving..."
            resolved_ip=$(resolve_entry "$entry")
            if [ -z "$resolved_ip" ]; then
                log setup "  - WARN: ${entry} 확인 실패. 건너<binary data, 2 bytes><binary data, 2 bytes><binary data, 2 bytes>."
                continue
            fi
            log setup "  - ${entry} -> ${resolved_ip} 경로 추가"
            ip route replace "$resolved_ip" via "${NS_VETH_IP}" dev "${VETH_MAIN}"
        else
            log setup "  - ${entry} 경로 추가"
            ip route replace "$entry" via "${NS_VETH_IP}" dev "${VETH_MAIN}"
        fi
    fi
done < <(sed -n '/\[routes\]/,/\[.*\]/p' "$CONF_FILE" | grep -v '\[.*\]')

sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
sysctl -w "net.ipv4.conf.${VETH_MAIN}.rp_filter=2" >/dev/null

log setup "선별적 경로 적용 완료"
