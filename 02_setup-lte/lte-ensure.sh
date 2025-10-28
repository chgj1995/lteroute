#!/usr/bin/env bash
set -Eeuo pipefail

# ===== User-tunable =====
APN="${APN:-iot.1nce.net}"
IP_TYPE="${IP_TYPE:-ipv4}"
CONF="/etc/lte_pbr.allow"          # 허용 대상 목록 (IP/CIDR, domain, dns ...)
STATE_DIR="/run"
ADDED_LIST="${STATE_DIR}/lte-pbr.dest"

# ===== Binaries =====
IPBIN="/bin/ip"
MM="/usr/bin/mmcli"

log(){ echo "$(date '+%F %T') [ensure-allow] $*" >&2; }
need_root(){ [ "$EUID" -eq 0 ] || { log "root 권한 필요 (sudo)"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- (1) LTE 연결 보장 + 검증 ----------
# 모뎀이 보일 때까지 대기
for _ in $(seq 1 40); do
  if $MM -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem/'; then break; fi
  sleep 0.5
done
MODEM_PATH="$($MM -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"

# 모뎀을 못 찾으면 실패로 종료 → systemd가 재시도
[ -n "$MODEM_PATH" ] || { log "No modem found (boot race). Exit 1 to retry"; exit 1; }
log "Modem: ${MODEM_PATH}"

pick_data_bearer() {
  local mp="$1" b BEARERS detail
  mapfile -t BEARERS < <($MM -m "$mp" 2>/dev/null | grep -o '/org/freedesktop/ModemManager1/Bearer/[0-9]\+')
  for b in "${BEARERS[@]}"; do
    detail="$($MM -b "$b" 2>/dev/null)"
    echo "$detail" | grep -q 'connected:[[:space:]]*yes' || continue
    if echo "$detail" | grep -q 'IPv4 configuration' && echo "$detail" | grep -q 'address:'; then
      echo "$b"; return 0
    fi
  done
  return 1
}

verify_connection() {
  local iface="$1" gw="$2"
  local targets=("8.8.8.8" "1.1.1.1" "9.9.9.9") ok=1
  if [ -z "${gw}" ]; then
    log "WARN: Gateway is empty, verification skipped for ${iface}."
    return 1
  fi
  ip link set "${iface}" up || true
  ip route replace "${gw}" dev "${iface}" scope link proto static 2>/dev/null || true
  for target in "${targets[@]}"; do
    log "Verifying ${iface}: temp route ${target} via ${gw}"
    ip route replace "${target}/32" via "${gw}" dev "${iface}" proto static metric 50 2>/dev/null || true
    for _ in $(seq 1 3); do
      if ping -I "${iface}" -c 1 -W 3 "${target}" >/dev/null 2>&1; then ok=0; break; fi
      sleep 1
    done
    ip route del "${target}/32" via "${gw}" dev "${iface}" 2>/dev/null || true
    [ $ok -eq 0 ] && break
  done
  [ $ok -ne 0 ] && log "WARN: Connection verification failed on ${iface}."
  return $ok
}

need_root

MAX_RETRIES=2
IFACE=""; ADDR=""; PFX=""; GW=""; DNS1=""; DNS2=""
for i in $(seq 1 ${MAX_RETRIES}); do
  log "--- Attempt ${i}/${MAX_RETRIES} to establish and verify LTE connection ---"

  if ! $MM -m "$MODEM_PATH" | grep -q 'state:[[:space:]]*connected'; then
    log "Modem not connected. Running simple-connect..."
    if ! $MM -m "$MODEM_PATH" --simple-connect="apn=${APN},ip-type=${IP_TYPE}" >/dev/null; then
      log "WARN: simple-connect failed. Retrying..."; sleep 3; continue
    fi
    log "Polling for a connected data bearer..."
    for _ in $(seq 1 15); do
      FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
      [ -n "$FINAL_BEARER_PATH" ] && break
      sleep 1
    done
  else
    log "Modem already 'connected'."
    FINAL_BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
  fi

  if [ -z "${FINAL_BEARER_PATH:-}" ]; then
    log "WARN: No usable (connected+IPv4) bearer. Retrying..."; sleep 3; continue
  fi
  log "Using data bearer: ${FINAL_BEARER_PATH}"

  DETAIL="$($MM -b "$FINAL_BEARER_PATH" 2>/dev/null || true)"
  IFACE="$(printf '%s\n' "$DETAIL" | sed -n 's/^[[:space:]]*|[[:space:]]*interface:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
  : "${IFACE:=wwan0}"
  BLK="$(printf '%s\n' "$DETAIL" | sed -n '/^  IPv4 configuration /,/^  --------------------------------/p')"
  ADDR="$(printf '%s\n' "$BLK" | sed -n 's/.*address:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
  PFX="$( printf '%s\n' "$BLK" | sed -n 's/.*prefix:[[:space:]]*\(.*\)$/\1/p'  | head -n1)"
  GW="$(  printf '%s\n' "$BLK" | sed -n 's/.*gateway:[[:space:]]*\(.*\)$/\1/p' | head -n1)"
  MTU="$( printf '%s\n' "$BLK" | sed -n 's/.*mtu:[[:space:]]*\(.*\)$/\1/p'     | head -n1)"
  DNS1="$(printf '%s\n' "$BLK" | sed -n 's/.*dns:[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
  DNS2="$(printf '%s\n' "$BLK" | sed -n 's/.*dns:[[:space:]]*[0-9.]\+,[[:space:]]*\([0-9.]\+\).*/\1/p' | head -n1)"
  log "Bearer IPv4: iface=${IFACE} ${ADDR}/${PFX} gw=${GW} dns=${DNS1},${DNS2}"

  if [ -z "${ADDR:-}" ] || [ -z "${GW:-}" ] || [ -z "${DNS1:-}" ]; then
    log "WARN: Incomplete IPv4 info. Retrying..."; sleep 3; continue
  fi

  # 인터페이스 up과 on-link GW 보장, IP 적용
  ${IPBIN} addr flush dev "${IFACE}" || true
  ${IPBIN} addr add "${ADDR}/${PFX}" dev "${IFACE}"
  ${IPBIN} link set "${IFACE}" up
  ${IPBIN} route replace "${GW}" dev "${IFACE}" scope link proto static || true

  # /run/resolvconf 경로 활용(있으면)
  mkdir -p /run/resolvconf/resolv.conf.d 2>/dev/null || true
  echo "nameserver ${DNS1}" > /run/resolvconf/resolv.conf.d/lte || true
  [ -n "${DNS2}" ] && echo "nameserver ${DNS2}" >> /run/resolvconf/resolv.conf.d/lte || true
  resolvconf -u 2>/dev/null || true

  if verify_connection "${IFACE}" "${GW}"; then
    log "--- LTE connection verified. Proceed to allow-list routing ---"
    break
  fi
  log "WARN: Verification failed. Will retry if attempts remain."
done

# 실패 시 systemd 재시도 유도
[ -n "${IFACE:-}" ] || { log "ERR: LTE connection not available."; exit 1; }

# ---------- (2) 허용대상 라우팅 적용 ----------
ensure_conf() {
  if [ ! -f "$CONF" ]; then
    cat >"$CONF" <<'EOF'
dns 8.8.8.8
dns 1.1.1.1
100.64.0.0/10
domain ntp.ubuntu.com
domain time.google.com
domain github.com
domain api.github.com
domain raw.githubusercontent.com
domain objects.githubusercontent.com
domain github-cloud.s3.amazonaws.com
EOF
    log "기본 설정파일 생성: $CONF"
  fi
}

resolve_domain_ipv4() {
  local d="$1"
  if have getent;   then getent ahostsv4 "$d" | awk '{print $1}' | grep -E '^[0-9]+' | sort -u; return 0; fi
  if have host;     then host -t A "$d" 2>/dev/null | awk '/has address/ {print $4}' | sort -u; return 0; fi
  if have nslookup; then nslookup -type=A "$d" 2>/dev/null | awk '/^Address: /{print $2}' | sort -u; return 0; fi
  return 1
}

# ★ 여기서 단 한 번만 .dest 초기화
prepare_dest() {
  mkdir -p "${STATE_DIR}" 2>/dev/null || true
  : > "${ADDED_LIST}" 2>/dev/null || true
}
prepare_dest

add_dst() {
  local dst="$1"
  # 여기서는 더 이상 truncate 금지! (prepare_dest에서 1회 초기화)
  if [ -n "$dst" ] && ! grep -qx -- "$dst" "$ADDED_LIST" 2>/dev/null; then
    echo "$dst" >> "$ADDED_LIST"
  fi
  if [[ "$dst" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    $IPBIN route replace "$dst" via "$GW" dev "$IFACE" proto static metric 50
  elif [[ "$dst" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    $IPBIN route replace "${dst}/32" via "$GW" dev "$IFACE" proto static metric 50
  else
    log "WARN: 잘못된 목적지 형식: $dst"
  fi
}

ensure_conf

declare -a DNS_IPS=() IPS=() DOMAINS=()
# (기존 파일 유지: 주석/공백 제거, 키워드 파싱)
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(echo "$line" | xargs || true)"
  [ -z "$line" ] && continue
  case "$line" in
    dns\ *)    DNS_IPS+=("${line#dns }");;
    ip\ *)     IPS+=("${line#ip }");;
    domain\ *) DOMAINS+=("${line#domain }");;
    *)
      if echo "$line" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'; then
        IPS+=("$line")
      elif echo "$line" | grep -Eq '^[A-Za-z0-9.-]+$'; then
        DOMAINS+=("$line")
      else
        log "무시: $line"
      fi
    ;;
  esac
done <"$CONF"

# 1) DNS 고정 IP 우선
if [ "${#DNS_IPS[@]}" -gt 0 ]; then
  log "DNS 우선 적용: ${DNS_IPS[*]}"
  for d in "${DNS_IPS[@]}"; do add_dst "$d"; done
fi

# 2) 도메인 해석 → IP
if [ "${#DOMAINS[@]}" -gt 0 ]; then
  for dom in "${DOMAINS[@]}"; do
    mapfile -t A4 < <(resolve_domain_ipv4 "$dom" || true)
    if [ "${#A4[@]}" -eq 0 ]; then
      log "WARN: 도메인 해석 실패: $dom"
      continue
    fi
    log "domain ${dom} -> ${A4[*]}"
    for ip4 in "${A4[@]}"; do IPS+=("$ip4"); done
  done
fi

# 3) IP/CIDR 일괄 적용(중복 제거)
if [ "${#IPS[@]}" -gt 0 ]; then
  mapfile -t IPS_U < <(printf "%s\n" "${IPS[@]}" | awk 'NF' | sort -u)
  for dst in "${IPS_U[@]}"; do add_dst "$dst"; done
fi

log "적용 완료. 추가된 목적지 목록:"
sort -u "$ADDED_LIST" 2>/dev/null | sed 's/^/  - /' || true
echo "== ip route | grep ${IFACE} =="
$IPBIN route show | grep -F " dev $IFACE" || true
