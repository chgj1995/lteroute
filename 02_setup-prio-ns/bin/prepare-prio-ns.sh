#!/usr/bin/env bash
set -Eeuo pipefail

# This script prepares the complete environment for the prio-ns-autoswitch service.
# It's called by ExecStartPre in the systemd service file.
# It expects the source directory path as its first argument.

if [ -z "$1" ] || [ ! -d "$1" ]; then
  echo "Error: Source directory path not provided or invalid." >&2
  exit 1
fi
SRC_DIR="$1"
ENSURE_SCRIPT="/usr/local/sbin/prio-ns-ensure.sh"

# Source common variables and functions
. "${SRC_DIR}/00_common.sh"

log(){ echo "$(date '+%F %T') [prepare] $*" >&2; }

log "--- Preparing prio_ns environment ---"

# Source scripts to ensure variables from 00_common.sh are available
# and they run in the same shell context.
log "Step 1/3: Creating namespace and veth..."
source "${SRC_DIR}/10_ns_create.sh"

log "Step 2/3: Setting up host NAT and FORWARD rules..."
source "${SRC_DIR}/60_nat_forward.sh"

log "Step 3/3: Ensuring LTE interface is ready..."
if [ -f "$ENSURE_SCRIPT" ]; then
  bash "$ENSURE_SCRIPT" # This one is standalone and installed, so bash is correct.
else
  log "WARN: $ENSURE_SCRIPT not found. Skipping LTE setup."
fi

log "--- Environment preparation complete ---"