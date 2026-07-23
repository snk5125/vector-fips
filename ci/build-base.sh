#!/usr/bin/env bash
# Build the patched UBI9 base image (Containerfile.base).
# Usage: build-base.sh [datetag]      (default: today, UTC, YYYY-MM-DD)
# Env:   BASE_IMAGE_REPO (registry/name), ARCH (amd64|arm64, default amd64)
set -euo pipefail

BASE_IMAGE_REPO="${BASE_IMAGE_REPO:-ghcr.io/snk5125/vector-fips/ubi9-patched}"
ARCH="${ARCH:-amd64}"
datetag="${1:-$(date -u +%Y-%m-%d)}"

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

revision="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
docker build -f Containerfile.base \
  --platform "linux/$ARCH" \
  --pull \
  --label "org.opencontainers.image.title=ubi9-patched" \
  --label "org.opencontainers.image.description=UBI9-minimal with latest el9 CVE backports + vector-fips package set" \
  --label "org.opencontainers.image.version=$datetag" \
  --label "org.opencontainers.image.revision=$revision" \
  --label "org.opencontainers.image.source=https://github.com/snk5125/vector-fips" \
  -t "$BASE_IMAGE_REPO:$datetag" -t "$BASE_IMAGE_REPO:latest" .

echo "build-base: $BASE_IMAGE_REPO:$datetag ($ARCH)"
