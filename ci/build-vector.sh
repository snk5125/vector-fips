#!/usr/bin/env bash
# Compile the custom FIPS-profile Vector binary into build/artifacts/.
# Host side: build the builder image, fetch + verify the pinned source,
# then run ci/compile-in-container.sh inside the builder with the source,
# cargo caches, and target dir bind-mounted (multi-GB build tree stays on
# the host disk, not in docker image layers).
# Usage: build-vector.sh            (arch = host arch; CI passes ARCH=amd64)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
# shellcheck source=ci/pins.sh
source ci/pins.sh

ARCH="${ARCH:-$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')}"
BUILDER_IMAGE="${BUILDER_IMAGE:-vector-fips/builder:local}"

src="$here/build/src"
mkdir -p build/{cargo,target,artifacts,vrl-patched,headers-patched}

# Reuse an existing artifact only when its manifest matches the pins.
if [ -x build/artifacts/vector ] && [ -f build/artifacts/build-manifest.json ] \
   && grep -q "\"$VECTOR_COMMIT\"" build/artifacts/build-manifest.json \
   && [ "$(cat build/artifacts/.arch 2>/dev/null)" = "$ARCH" ] \
   && [ "${FORCE_REBUILD:-}" != "1" ]; then
  echo "build-vector: artifact for $VECTOR_TAG/$ARCH already present (FORCE_REBUILD=1 to override)"
  exit 0
fi

echo "== builder image"
docker build -f Containerfile.builder --platform "linux/$ARCH" -t "$BUILDER_IMAGE" .

echo "== source: $VECTOR_TAG (expect $VECTOR_COMMIT)"
if [ ! -d "$src/.git" ]; then
  git clone --depth 1 --branch "$VECTOR_TAG" "$VECTOR_REPO" "$src"
fi
got="$(git -C "$src" rev-parse HEAD)"
if [ "$got" != "$VECTOR_COMMIT" ]; then
  echo "build-vector: COMMIT MISMATCH for $VECTOR_TAG" >&2
  echo "  want: $VECTOR_COMMIT" >&2
  echo "  got:  $got" >&2
  exit 1
fi
# discard any leftover patch state from a previous run; the compile script
# re-applies it (idempotent, exact-match)
git -C "$src" checkout -q -- Cargo.toml Cargo.lock 2>/dev/null || true

echo "== compile (features: ci/features-fips.txt)"
docker run --rm \
  --platform "linux/$ARCH" \
  -v "$src:/work/src" \
  -v "$here/build/cargo:/work/cargo" \
  -v "$here/build/target:/work/target" \
  -v "$here/build/artifacts:/work/artifacts" \
  -v "$here/build/vrl-patched:/work/vrl-patched" \
  -v "$here/build/headers-patched:/work/headers-patched" \
  -v "$here/ci:/work/ci:ro" \
  -e VECTOR_TAG="$VECTOR_TAG" \
  -e VRL_COMMIT="$VRL_COMMIT" \
  ${CARGO_BUILD_JOBS:+-e CARGO_BUILD_JOBS="$CARGO_BUILD_JOBS"} \
  "$BUILDER_IMAGE" bash /work/ci/compile-in-container.sh

echo "$ARCH" > build/artifacts/.arch
echo "build-vector: OK ($ARCH)"
