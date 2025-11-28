#!/usr/bin/env bash
set -euo pipefail

# Cross-compile helper for the root module
# Uncomment one GOOS/GOARCH pair if you need cross-compiling.
# GOOS="linux";   GOARCH="amd64"   # Linux AMD64
GOOS="linux";   GOARCH="arm64"   # Linux ARM64
# GOOS="windows"; GOARCH="amd64"   # Windows AMD64
# Leave empty to build for host platform.
GOOS="${GOOS:-}"
GOARCH="${GOARCH:-}"
OUT="${OUT:-lteroute}"

if [ -n "$GOOS" ] || [ -n "$GOARCH" ]; then
    echo "Cross-compiling with GOOS=$GOOS GOARCH=$GOARCH"
else
    echo "Building for host platform..."
fi

mkdir -p "build"
GOOS=$GOOS GOARCH=$GOARCH go build -o "build/$OUT" .
echo "Build complete. Binary: $(pwd)/build/$OUT (GOOS=${GOOS:-host} GOARCH=${GOARCH:-host})"
