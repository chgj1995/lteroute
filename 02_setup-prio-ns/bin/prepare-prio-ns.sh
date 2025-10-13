#!/usr/bin/env bash
set -Eeuo pipefail

# This script prepares the complete environment for the prio-ns-autoswitch service.
# It's called by ExecStartPre in the systemd service file.
# It assumes it's being run from the 02_setup-prio-ns directory,
# which is set by WorkingDirectory in the service definition.

log(){ echo "$(date '+%F %T') [prepare] $*" >&2; }

log "--- Preparing prio_ns environment ---"

# Source common variables and functions.
# The scripts below depend on this.
source ./00_common.sh

log "Step 1/3: Creating namespace and veth..."
source ./10_ns_create.sh

log "Step 2/3: Setting up host NAT and FORWARD rules..."
source ./60_nat_forward.sh

log "Step 3/3: Ensuring LTE interface is ready..."
# ensure script is also sourced to inherit common functions and variables
source ./bin/prio-ns-ensure.sh

log "--- Environment preparation complete ---"