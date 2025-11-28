#!/bin/bash

# Upload built binary to a remote host. Fill in the values below before running.
LOCAL_FILE="build/lteroute"               # path to the local binary to send
# LOCAL_FILE="build/patcher"               # path to the local binary to send
REMOTE_USER="ubuntu"                        # remote ssh username
REMOTE_HOST="192.168.0.59"                  # remote host or IP
REMOTE_PORT="22"                            # ssh port (default 22)
REMOTE_PATH="/home/ubuntu/workspace/lteroute" # remote destination path

if [ ! -f "$LOCAL_FILE" ]; then
    echo "File not found: $LOCAL_FILE"
    exit 1
fi

echo "Uploading $LOCAL_FILE to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
scp -P "$REMOTE_PORT" "$LOCAL_FILE" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
