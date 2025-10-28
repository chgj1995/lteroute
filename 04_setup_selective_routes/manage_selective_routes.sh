#!/usr/bin/env bash
set -Eeuo pipefail

# --- common.sh의 내용 통합 ---
NS="${NS:-prio_ns}"
VETH_MAIN="${VETH_MAIN:-veth-main}"
VETH_NS="${VETH_NS:-veth-ns}"
MAIN_IP_CIDR="${MAIN_IP_CIDR:-10.254.0.1/30}"
NS_IP_CIDR="${NS_IP_CIDR:-10.254.0.2/30}"
HOST_VETH_IP="${HOST_VETH_IP:-${MAIN_IP_CIDR%/*}}"
NS_VETH_IP="${NS_VETH_IP:-${NS_IP_CIDR%/*}}"

log(){ echo "$(date '+%F %T') [$1] ${2:-}" >&2; }
die(){ log "err" "$1"; exit 1; }
as_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root"; }
ns_exists(){ ip netns list | grep -q "^${NS}\b"; }
require_prio_ns(){ ns_exists || die "네임스페이스 자동탐지 실패"; }
# --- 통합 끝 ---

as_root
ACTION="${1:-up}"
CONF_FILE="/etc/prio-ns/selective_routes.conf"

if [ ! -f "$CONF_FILE" ]; then
    die "설정 파일(${CONF_FILE})을 찾을 수 없습니다."
fi

log setup "선별적 경로 관리 (${ACTION})"

# --- helpers ---
get_clean_entry() {
    echo "$1" | sed 's/#.*//' | xargs
}

resolve_entry() {
    local entry="$1"
    ip netns exec "${NS}" getent ahosts "$entry" | awk '{print $1}'
}

# --- main logic ---
if [ "$ACTION" = "up" ]; then
    require_prio_ns
    if ! ip netns exec "${NS}" ip route show default | grep -q .; then
        log setup "WARN: prio_ns에 기본 경로가 없어 추가합니다."
        ip netns exec "${NS}" ip route add default via "${HOST_VETH_IP}" dev "${VETH_NS}" metric 10
    fi

    log setup "1단계: DNS 서버 설정 및 경로 추가"
    DNS_SERVERS=()
    while read -r line; do
        entry=$(get_clean_entry "$line")
        if [ -n "$entry" ]; then
            log setup "  - 경로 추가: ${entry}"
            ip route replace "$entry" via "${NS_VETH_IP}" dev "${VETH_MAIN}"
            DNS_SERVERS+=("$entry")
        fi
    done < <(sed -n '/\[dns_servers\]/,/\[.*\]/p' "$CONF_FILE" | grep -v '\[.*\]')

    if [ ${#DNS_SERVERS[@]} -gt 0 ]; then
        log setup "  - prio_ns에 DNS 서버 설정 적용"
        mkdir -p "/etc/netns/${NS}"
        (printf "nameserver %s\n" "${DNS_SERVERS[@]}") > "/etc/netns/${NS}/resolv.conf"
    fi

    log setup "2단계: 나머지 경로 설정"
    while read -r line; do
        entry=$(get_clean_entry "$line")
        if [ -n "$entry" ]; then
            resolved_ips=($(resolve_entry "$entry"))
            if [ ${#resolved_ips[@]} -eq 0 ]; then
                log setup "  - WARN: ${entry} 확인 실패."
                continue
            fi
            for ip in "${resolved_ips[@]}"; do
                log setup "  - 경로 추가: ${entry} -> ${ip}"
                ip route replace "$ip" via "${NS_VETH_IP}" dev "${VETH_MAIN}"
            done
        fi
    done < <(sed -n '/\[routes\]/,/\[.*\]/p' "$CONF_FILE" | grep -v '\[.*\]')

elif [ "$ACTION" = "down" ]; then
    log setup "제거 시작..."

    while read -r line; do
        entry=$(get_clean_entry "$line")
        if [ -n "$entry" ]; then
            log setup "  - 경로 제거: ${entry}"
            ip route del "$entry" 2>/dev/null || true
        fi
    done < <(sed -n '/\[dns_servers\]/,/\[.*\]/p' "$CONF_FILE" | grep -v '\[.*\]')

     while read -r line; do
        entry=$(get_clean_entry "$line")
        if [[ -n "$entry" && "$entry" =~ ^[0-9./]+$ ]]; then
            log setup "  - 경로 제거: ${entry}"
            ip route del "$entry" 2>/dev/null || true
        fi
    done < <(sed -n '/\[routes\]/,/\[.*\]/p' "$CONF_FILE" | grep -v '\[.*\]')

else
    die "잘못된 인자: 'up' 또는 'down'을 사용하세요."
fi

log setup "선별적 경로 관리 완료"
