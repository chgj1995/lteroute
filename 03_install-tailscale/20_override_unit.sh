#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/00_common.sh"; as_root

log tailscale "Removing systemd override for tailscaled.service..."

# Remove the override file to revert to the default service behavior
rm -f /etc/systemd/system/tailscaled.service.d/override.conf

log tailscale "Systemd override file removed."
