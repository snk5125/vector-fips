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

# bindgen (zstd-sys): el9's clang-libs lives in /usr/lib64 but the builtin
# headers (clang-resource-filesystem) are under /usr/lib/clang — libclang
# doesn't derive that resource dir on its own.
clang_inc="$(echo /usr/lib/clang/*/include)"
[ -f "$clang_inc/stddef.h" ] && export BINDGEN_EXTRA_CLANG_ARGS="-I$clang_inc"

cd /work/src

features="$(grep -vE '^\s*(#|$)' /work/ci/features-fips.txt | tr '\n' ',' | sed 's/,$//')"
[ -n "$features" ] || { echo "compile: empty feature list" >&2; exit 1; }
echo "== features: $features"

# --- source patches (shared with the audit: ci/apply-source-patches.sh) -----
bash /work/ci/apply-source-patches.sh

# Settle Cargo.lock after the patches. Feature drops can only REMOVE
# packages from the max resolve graph, and the vrl [patch] rewrites vrl's
# source to the vendored path. Gate: the lock diff must not ADD any package
# — additions would mean the resolution changed beyond the intended
# removals/substitution.
cargo tree -p vector --no-default-features --prefix none -q >/dev/null
if git diff Cargo.lock | grep -E '^\+name = '; then
  echo "compile: Cargo.lock gained packages after source patches — abort" >&2
  exit 1
fi
echo "== lock settled ($(git diff --numstat Cargo.lock | awk '{print $2" removals, "$1" additions"}'))"

# --- pinned security bumps (ci/crate-bumps.txt) -----------------------------
# Exact from->to updates for advisories fixed in semver-compatible releases.
# A stale line (upstream moved past <from>) fails loudly for review.
while read -r spec to advisory; do
  case "$spec" in ''|\#*) continue ;; esac
  echo "== crate bump: $spec -> $to ($advisory)"
  cargo update -p "$spec" --precise "$to"
done < /work/ci/crate-bumps.txt

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
# vrl is a path dep after the [patch] substitution (no source line in the
# lock) — the pin is the env the patch script asserted against the lock.
vrl_pin="${VRL_COMMIT:-unknown}"
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
    "patches": [
        "tonic: removed rustls-based 'tls','tls-roots' features (gRPC TLS is via vector's OpenSSL MaybeTlsSettings)",
        "reqwest_13: made optional, gated behind excluded sinks-azure_blob (was unconditionally dragging the rustls 0.23 stack)",
        "vrl@" + os.environ.get('VRL_COMMIT', 'unknown')[:9] + ": community_id() stdlib function removed (RustCrypto SHA-1)",
        "headers@0.3.9: SecWebsocketAccept type + sha1 dependency removed (websocket handshake SHA-1; no websocket component in the feature set)",
        "vector-core: gRPC connect-info stores peer-cert PEM bytes directly instead of tonic::transport::Certificate (type is gated behind tonic's removed rustls tls feature; peer_certs has no consumers)",
    ],
    "profile_overrides": {"lto": "thin (upstream: fat; RAM-bound builders; perf-only deviation)",
                          "codegen-units": 16},
}, indent=2))
EOF
echo "== artifacts ready:"
ls -l /work/artifacts/
