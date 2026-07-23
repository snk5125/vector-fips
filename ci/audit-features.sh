#!/usr/bin/env bash
# Per-feature crypto dependency audit — the generator behind
# docs/removed-functionality.md and ci/features-fips.txt.
#
# For every individual component feature of the pinned Vector source, resolve
# its dependency closure (cargo tree, no compile) and report which features
# introduce crates from ci/forbidden-crates.txt. Runs the resolution inside
# the builder image; caches in build/. Takes ~15-25 min cold.
#
# Usage: audit-features.sh          -> build/audit/audit.tsv
# The final feature set is separately hard-gated at compile time
# (ci/compile-in-container.sh) — this full sweep is for (re)generating the
# classification when bumping the Vector pin.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
# shellcheck source=ci/pins.sh
source ci/pins.sh

ARCH="${ARCH:-$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')}"
BUILDER_IMAGE="${BUILDER_IMAGE:-vector-fips/builder:local}"

docker build -f Containerfile.builder --platform "linux/$ARCH" -t "$BUILDER_IMAGE" . >/dev/null

src="$here/build/src"
if [ ! -d "$src/.git" ]; then
  git clone --depth 1 --branch "$VECTOR_TAG" "$VECTOR_REPO" "$src"
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$VECTOR_COMMIT" ] || { echo "audit: source commit mismatch" >&2; exit 1; }
git -C "$src" checkout -q -- Cargo.toml Cargo.lock 2>/dev/null || true

mkdir -p build/{cargo,audit,vrl-patched,headers-patched}
docker run --rm \
  --platform "linux/$ARCH" \
  -v "$src:/work/src" \
  -v "$here/build/cargo:/work/cargo" \
  -v "$here/build/audit:/work/audit" \
  -v "$here/build/vrl-patched:/work/vrl-patched" \
  -v "$here/build/headers-patched:/work/headers-patched" \
  -v "$here/ci:/work/ci:ro" \
  -e VRL_COMMIT="$VRL_COMMIT" \
  "$BUILDER_IMAGE" bash -c '
set -euo pipefail
export CARGO_HOME=/work/cargo PATH=/opt/cargo/bin:$PATH RUSTUP_TOOLCHAIN=1.95.0
cd /work/src

# identical source patches to the real build
bash /work/ci/apply-source-patches.sh
cargo tree -p vector --no-default-features --prefix none -q >/dev/null 2>&1 || true

FORBID="^($(grep -vE "^\s*(#|$)" /work/ci/forbidden-crates.txt | tr "\n" "|" | sed "s/|$//")) "

tree() {
  if [ -n "$1" ]; then
    cargo tree -p vector --no-default-features -F "$1" --prefix none -e normal --locked -q 2>/work/audit/err.txt
  else
    cargo tree -p vector --no-default-features --prefix none -e normal --locked -q 2>/work/audit/err.txt
  fi
}

tree "" | awk "{print \$1\" \"\$2}" | sort -u > /work/audit/baseline.txt
[ -s /work/audit/baseline.txt ] || { echo "baseline empty" >&2; cat /work/audit/err.txt >&2; exit 1; }
grep -E "$FORBID" /work/audit/baseline.txt > /work/audit/baseline-hits.txt || true

feats="$(grep -E "^(sources|sinks|transforms)-[a-z0-9_]+ = \[" Cargo.toml | cut -d= -f1 | tr -d " " \
        | grep -vE "^(sources|sinks|transforms)-(logs|metrics)$" \
        | grep -v windows_event_log)
api
api-client
enrichment-tables
codecs-syslog
codecs-opentelemetry
codecs-parquet
secrets
vrl-functions-env
vrl-functions-system
vrl-functions-network
vrl-functions-crypto"

: > /work/audit/audit.tsv
for f in $feats; do
  echo "== $f" >&2
  if ! tree "$f" | awk "{print \$1\" \"\$2}" | sort -u > /work/audit/cur.txt || [ ! -s /work/audit/cur.txt ]; then
    printf "%s\tRESOLVE_ERROR\t%s\n" "$f" "$(head -1 /work/audit/err.txt | tr "\t" " ")" >> /work/audit/audit.tsv
    continue
  fi
  hits=$(grep -E "$FORBID" /work/audit/cur.txt | comm -13 /work/audit/baseline-hits.txt - | tr "\n" "," | sed "s/,$//")
  if [ -n "$hits" ]; then
    printf "%s\tFORBIDDEN\t%s\n" "$f" "$hits" >> /work/audit/audit.tsv
  else
    printf "%s\tCLEAN\t-\n" "$f" >> /work/audit/audit.tsv
  fi
done
'
echo "audit: build/audit/audit.tsv"
column -t -s"$(printf '\t')" build/audit/audit.tsv
