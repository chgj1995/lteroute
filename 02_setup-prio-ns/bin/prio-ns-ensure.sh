#!/usr/bin/env bash
set -Eeuo pipefail

NS="prio_ns"
VETH_MAIN="veth-main"
VETH_NS="veth-ns"
HOST_IP="10.254.0.1/30"
NS_IP="10.254.0.2/30"

APN="${APN:-iot.1nce.net}"
IP_TYPE="${IP_TYPE:-ipv4}"

IPBIN="/bin/ip"
MM="/usr/bin/mmcli"

log(){ echo "$(date '+%F %T') [ensure] $*" >&2; }

# 0) prio_ns / veth 보장
$IPBIN netns list | grep -q "^${NS}\b" || $IPBIN netns add "${NS}"
$IPBIN link show "${VETH_MAIN}" >/dev/null 2>&1 || $IPBIN link add "${VETH_MAIN}" type veth peer name "${VETH_NS}"
$IPBIN link set "${VETH_NS}" netns "${NS}" 2>/dev/null || true
$IPBIN addr show dev "${VETH_MAIN}" | grep -q "${HOST_IP}" || $IPBIN addr add "${HOST_IP}" dev "${VETH_MAIN}" || true
$IPBIN link set "${VETH_MAIN}" up || true
$IPBIN netns exec "${NS}" bash -lc "
  ip addr show dev ${VETH_NS} | grep -q '${NS_IP}' || ip addr add ${NS_IP} dev ${VETH_NS} || true
  ip link set ${VETH_NS} up || true
  ip link set lo up || true
"

# 1) ModemManager가 모뎀을 인식할 때까지 대기(최대 20초)
for _ in $(seq 1 40); do
  if $MM -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem/'; then break; fi
  sleep 0.5
done
MODEM_PATH="$($MM -L 2>/dev/null | sed -n 's/^[[:space:]]*\([/].*Modem\/[0-9]\+\).*/\1/p' | head -n1)"
[ -n "$MODEM_PATH" ] || { log "No modem found; skip LTE"; exit 0; }
log "Modem: ${MODEM_PATH}"

# 2) 미연결이면 simple-connect 시도(무해)
if ! $MM -m "$MODEM_PATH" 2>/dev/null | grep -q 'state:.*connected'; then
  log "simple-connect APN=${APN}, ip-type=${IP_TYPE}"
  $MM -m "$MODEM_PATH" --simple-connect="apn=${APN},ip-type=${IP_TYPE}" >/dev/null 2>&1 || true
  sleep 1
fi

# 3) IPv4 configuration이 실제로 있는 '데이터 베어러'만 선택
pick_data_bearer() {
  local mp="$1" b
  mapfile -t BEARERS < <($MM -m "$mp" --list-bearers 2>/dev/null \
    | sed -n 's/.*\(\/org\/freedesktop\/ModemManager1\/Bearer\/[0-9]\+\).*/\1/p')
  for b in "${BEARERS[@]}"; do
    $MM -b "$b" 2>/dev/null | grep -q 'connected:[[:space:]]*yes' || continue
    $MM -b "$b" -K 2>/dev/null | grep -q '^bearer.ipv4.method:' || continue
    echo "$b"; return 0
  done
  return 1
}

BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
if [ -z "$BEARER_PATH" ]; then
  log "No data bearer; create+connect"
  NEW_BEARER=$($MM -m "$MODEM_PATH" --create-bearer="apn=${APN},ip-type=${IP_TYPE}" \
               | sed -n 's/.*\(\/org\/freedesktop\/ModemManager1\/Bearer\/[0-9]\+\).*/\1/p' || true)
  if [ -n "$NEW_BEARER" ]; then
    $MM -b "$NEW_BEARER" --connect >/dev/null 2>&1 || true
    sleep 1
    BEARER_PATH="$(pick_data_bearer "$MODEM_PATH" || true)"
  fi
fi
[ -n "$BEARER_PATH" ] || { log "No usable bearer (connected+IPv4)"; exit 0; }

# 4) IPv4/IFACE 파싱 (mmcli -K key=value 파싱)
eval "$(
  $MM -b "$BEARER_PATH" -K 2>/dev/null | awk -F= '
    $1=="bearer.interface"         { printf("IFACE=\"%s\"\n",$2) }
    $1=="bearer.ipv4.address"      { printf("ADDR=\"%s\"\n",$2) }
    $1=="bearer.ipv4.prefix"       { printf("PFX=\"%s\"\n",$2) }
    $1=="bearer.ipv4.gateway"      { printf("GW=\"%s\"\n",$2) }
    $1=="bearer.ipv4.mtu"          { printf("MTU=\"%s\"\n",$2) }
    $1=="bearer.ipv4.dns1"         { printf("DNS1=\"%s\"\n",$2) }
    $1=="bearer.ipv4.dns2"         { printf("DNS2=\"%s\"\n",$2) }
  '
)"
: "${IFACE:=wwan0}"
log "Bearer: ${BEARER_PATH} iface=${IFACE} ${ADDR}/${PFX} gw=${GW} mtu=${MTU} dns=${DNS1} ${DNS2}"

# 5) 인터페이스를 지금 NS로 이동
if $IPBIN link show "$IFACE" >/dev/null 2>&1; then
  $IPBIN link set "$IFACE" netns "$NS" 2>/dev/null || true
fi

# 6) netns 안에서 IP/라우트/DNS 적용 (MBIM: onlink 중요)
if [ -n "${ADDR:-}" ] && [ -n "${PFX:-}" ]; then
  $IPBIN netns exec "$NS" bash -lc "
    ip addr flush dev ${IFACE} || true
    ip addr add ${ADDR}/${PFX} dev ${IFACE}
    [ -n '${MTU:-}' ] && ip link set ${IFACE} mtu ${MTU}
    ip link set ${IFACE} up
    [ -n '${GW:-}' ] && ip route replace default via ${GW} dev ${IFACE} metric 100 onlink
  "
  mkdir -p "/etc/netns/${NS}"
  {
    [ -n "${DNS1:-}" ] && echo "nameserver ${DNS1}"
    [ -n "${DNS2:-}" ] && echo "nameserver ${DNS2}"
  } | tee "/etc/netns/${NS}/resolv.conf" >/dev/null
  log "Applied LTE IPv4 in ${NS}"
else
  log "IPv4 params incomplete; skip"
fi

exit 0
