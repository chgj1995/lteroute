#!/usr/bin/env bash
# This script is for debugging network state, to be called from other scripts.
set -x

NS="prio_ns"
log(){ echo "$(date '+%F %T') [debug] $*" >&2; }

log "--- Start Network State Dump ---"

log "1. Host iptables NAT table"
iptables -t nat -L -v -n

log "2. Host iptables FILTER table"
iptables -t filter -L -v -n

log "3. NS [${NS}] - IP Addresses"
ip netns exec "${NS}" ip addr show

log "4. NS [${NS}] - Route Table"
ip netns exec "${NS}" ip route show

log "--- End Network State Dump ---"
set +x