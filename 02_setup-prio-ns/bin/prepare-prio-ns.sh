#!/usr/bin/env bash
set -Eeuo pipefail

# This script prepares the complete environment for the prio-ns-autoswitch service.
# It's called by ExecStartPre in the systemd service file.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)" # Go up to 02_setup-prio-ns
ENSURE_SCRIPT="/usr/local/sbin/prio-ns-ensure.sh"

log(){ echo "$(date '+%F %T') [prepare] $*" >&2; }

log "--- Preparing prio_ns environment ---"

log "Step 1/3: Creating namespace and veth..."
bash "${SCRIPT_DIR}/10_ns_create.sh"

log "Step 2/3: Setting up host NAT and FORWARD rules..."
bash "${SCRIPT_DIR}/60_nat_forward.sh"

log "Step 3/3: Ensuring LTE interface is ready..."
if [ -f "$ENSURE_SCRIPT" ]; then
  bash "$ENSURE_SCRIPT"
else
  log "WARN: $ENSURE_SCRIPT not found. Skipping LTE setup."
fi

log "--- Environment preparation complete ---"