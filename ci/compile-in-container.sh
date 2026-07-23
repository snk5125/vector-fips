#!/usr/bin/env bash
# Runs INSIDE the builder image (Containerfile.builder), invoked by
# ci/build-vector.sh with:
#   /work/src        vector source checkout (pinned tag, verified by caller)
#   /work/target     cargo target dir (bind mount — kept off image layers)
#   /work/cargo      cargo registry/git cache (bind mount)
#   /work/artifacts  output: vector binary + build manifest + audit evidence
#   /work/ci         this repo's ci/ dir (features/forbid lists, pins)
set -euo pipefail

export CARGO_TARGET_DIR=/work/target
export CARGO_HOME=/work/cargo
export PATH=/opt/cargo/bin:$PATH
# rust-toolchain.toml wants profile "default" (clippy & co); the pinned
# builder toolchain is the same version with profile minimal — force it.
export RUSTUP_TOOLCHAIN=${RUST_VERSION:-1.95.0}

# Upstream GA builds use lto="fat". Fat LTO on a binary this size needs more
# RAM than our builders have; thin LTO is the documented, deliberate
# deviation (performance-only — no functional/crypto difference).
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16

cd /work/src

features="$(grep -vE '^\s*(#|$)' /work/ci/features-fips.txt | tr '\n' ',' | sed 's/,$//')"
[ -n "$features" ] || { echo "compile: empty feature list" >&2; exit 1; }
echo "== features: $features"

# --- patch: drop tonic's rustls-based tls features --------------------------
# Vector terminates gRPC TLS itself via its OpenSSL MaybeTlsSettings; the
# workspace tonic declaration enables tonic's own rustls stack, which would
# put rustls+ring in every gRPC component's dependency closure. Exact-match
# so a version bump that changes this line fails loudly for review.
old='tonic = { version = "0.11", default-features = false, features = ["transport", "codegen", "prost", "tls", "tls-roots", "gzip", "zstd"] }'
new='tonic = { version = "0.11", default-features = false, features = ["transport", "codegen", "prost", "gzip", "zstd"] }'
if grep -qF "$new" Cargo.toml; then
  echo "== tonic patch already applied"
else
  grep -qF "$old" Cargo.toml || { echo "compile: tonic line changed upstream — review the patch" >&2; exit 1; }
  python3 - "$old" "$new" <<'EOF'
import sys
old, new = sys.argv[1], sys.argv[2]
s = open('Cargo.toml').read()
assert s.count(old) == 1
open('Cargo.toml', 'w').write(s.replace(old, new))
EOF
  echo "== tonic patch applied (removed features: tls, tls-roots)"
fi

# Settle Cargo.lock after the patch (dropping features can only REMOVE
# packages from the max resolve graph). Gate: the lock diff must not ADD
# any package — additions would mean the resolution changed beyond the
# intended removal.
cargo tree -p vector --no-default-features --prefix none -q >/dev/null
if git diff Cargo.lock | grep -E '^\+name = '; then
  echo "compile: Cargo.lock gained packages after tonic patch — abort" >&2
  exit 1
fi
echo "== lock settled ($(git diff --numstat Cargo.lock | awk '{print $2" removals, "$1" additions"}'))"

# --- gate: forbidden crypto crates must be absent from the final graph ------
cargo tree -p vector --no-default-features -F "$features" --prefix none -e normal --locked -q \
  | awk '{print $1" "$2}' | sort -u > /work/artifacts/cargo-tree.txt
mapfile -t forbidden < <(grep -vE '^\s*(#|$)' /work/ci/forbidden-crates.txt)
bad=0
for crate in "${forbidden[@]}"; do
  if hit="$(grep -E "^${crate} " /work/artifacts/cargo-tree.txt)"; then
    echo "compile: FORBIDDEN crate in dependency graph: $hit" >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1
echo "== crypto gate: $(wc -l < /work/artifacts/cargo-tree.txt) crates resolved, 0 forbidden"

# --- build ------------------------------------------------------------------
# `cargo auditable` embeds the resolved dependency list into the binary so
# trivy's rust-audit detector can scan it (ci/scan.sh).
cargo auditable build --release --locked --no-default-features --features "$features"

bin="$CARGO_TARGET_DIR/release/vector"
[ -x "$bin" ]

# --- post-build gates -------------------------------------------------------
# OpenSSL must be statically linked (vendored): no dynamic libssl/libcrypto.
if ldd "$bin" | grep -E 'libssl|libcrypto'; then
  echo "compile: binary dynamically links OpenSSL — expected vendored/static" >&2
  exit 1
fi
# ...but the executable itself must be dynamic (glibc) so the statically
# linked libcrypto can dlopen the container's FIPS provider module.
ldd "$bin" | grep -q 'libc.so' || { echo "compile: not a dynamic executable — provider dlopen impossible" >&2; exit 1; }
"$bin" --version

# --- artifacts + manifest ---------------------------------------------------
cp "$bin" /work/artifacts/vector
openssl_src_ver="$(awk '/^name = "openssl-src"/{f=1} f && /^version/{print $3; exit}' Cargo.lock | tr -d '"')"
vrl_pin="$(awk '/^name = "vrl"/{f=1} f && /^source/{print; exit}' Cargo.lock | sed 's/.*#//; s/"//')"
python3 - "$features" "$openssl_src_ver" "$vrl_pin" > /work/artifacts/build-manifest.json <<'EOF'
import json, subprocess, sys, os
features, openssl_src, vrl_pin = sys.argv[1], sys.argv[2], sys.argv[3]
sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
tag = os.environ.get('VECTOR_TAG', 'unknown')
rustc = subprocess.check_output(['rustc', '--version'], text=True).strip()
print(json.dumps({
    "vector_tag": tag,
    "vector_commit": sha,
    "rustc": rustc,
    "openssl_src_version": openssl_src,
    "vrl_git_commit": vrl_pin,
    "cargo_features": sorted(features.split(',')),
    "patches": ["tonic: removed rustls-based 'tls','tls-roots' features (gRPC TLS is via vector's OpenSSL MaybeTlsSettings)"],
    "profile_overrides": {"lto": "thin (upstream: fat; RAM-bound builders; perf-only deviation)",
                          "codegen-units": 16},
}, indent=2))
EOF
echo "== artifacts ready:"
ls -l /work/artifacts/
