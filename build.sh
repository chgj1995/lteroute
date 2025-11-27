#!/usr/bin/env bash
set -euo pipefail

# Basic build helper for the single binary (cmd/lteroute).
# You can override GOOS/GOARCH; defaults target Linux AMD64.

GOOS="${GOOS:-linux}"
GOARCH="${GOARCH:-amd64}"
OUTPUT="${OUTPUT:-bin/lteroute}"

echo "Building for GOOS=${GOOS} GOARCH=${GOARCH} -> ${OUTPUT}"
mkdir -p "$(dirname "${OUTPUT}")"
GOOS="${GOOS}" GOARCH="${GOARCH}" go build -o "${OUTPUT}" .
echo "Done."
