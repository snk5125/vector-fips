#!/usr/bin/env bash
# Build the vector-fips image with OCI labels.
# Usage: build.sh [version]        (default: sha-<short-sha>)
# Env:   IMAGE (registry/name), ARCH (amd64|arm64, default host arch),
#        BASE_IMAGE (override the base reference entirely)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
# shellcheck source=ci/pins.sh
source ci/pins.sh

IMAGE="${IMAGE:-ghcr.io/snk5125/vector-fips}"
ARCH="${ARCH:-$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')}"
version="${1:-sha-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"

# Compile (or reuse) the custom vector binary for this arch.
ARCH="$ARCH" ./ci/build-vector.sh

# Base image resolution:
#   - BASE_IMAGE env overrides everything.
#   - If the Containerfile carries a published digest pin (maintained by
#     .github/workflows/base.yml), amd64 builds use it as-is.
#   - Otherwise (bootstrap, or arm64 dev where the published pin is amd64):
#     self-build an equivalent local base.
base_args=()
if [ -n "${BASE_IMAGE:-}" ]; then
  base_args=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
elif [ "$ARCH" != "amd64" ] || ! grep -qE '^ARG BASE_IMAGE=.*@sha256:' Containerfile; then
  BASE_IMAGE_REPO="vector-fips/ubi9-patched-local" ARCH="$ARCH" ./ci/build-base.sh local
  base_args=(--build-arg "BASE_IMAGE=vector-fips/ubi9-patched-local:local")
fi

revision="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
docker build -f Containerfile \
  --platform "linux/$ARCH" \
  ${base_args[@]+"${base_args[@]}"} \
  --label "org.opencontainers.image.title=vector-fips" \
  --label "org.opencontainers.image.description=FIPS-mode Vector aggregator (custom build, UBI9 + validated OpenSSL FIPS provider)" \
  --label "org.opencontainers.image.version=$version" \
  --label "org.opencontainers.image.revision=$revision" \
  --label "org.opencontainers.image.source=https://github.com/snk5125/vector-fips" \
  --label "io.grimoire.component=vector-fips" \
  --label "io.grimoire.vector.version=$VECTOR_VERSION" \
  --label "io.grimoire.vector.commit=$VECTOR_COMMIT" \
  -t "$IMAGE:$version" -t "$IMAGE:latest" .

echo "build: $IMAGE:$version ($ARCH)"
