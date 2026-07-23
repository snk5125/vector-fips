#!/usr/bin/env bash
# Apply the FIPS source patches to a pinned vector checkout (cwd). Shared by
# ci/compile-in-container.sh (real build) and ci/audit-features.sh (audit) so
# classification and compilation always see the same source. Idempotent; every
# patch is exact-match asserted so upstream drift on a version bump fails
# loudly for review instead of silently un-patching.
#
# Patches (rationale in docs/removed-functionality.md):
#   1. tonic: drop rustls-based "tls","tls-roots" features — vector performs
#      gRPC TLS via its OpenSSL MaybeTlsSettings; tonic's own TLS stack is
#      unused but would put rustls in every gRPC component's closure.
#   2. reqwest_13: mark optional and tie to sinks-azure_blob (its only
#      consumer). Upstream declares it unconditionally, which drags the
#      rustls 0.23 stack into EVERY build, including ours (azure_blob is
#      excluded).
#   3. vrl: remove the community_id() stdlib function — Community ID flow
#      hashes are SHA-1 by definition and vrl computes them with RustCrypto
#      `sha1`. It lives in stdlib-base (not the crypto feature group), so it
#      must be patched out. The pinned vrl commit is vendored, patched, and
#      substituted via [patch].
set -euo pipefail

VRL_COMMIT="${VRL_COMMIT:?apply-source-patches: VRL_COMMIT env required}"
VRL_REPO="${VRL_REPO:-https://github.com/vectordotdev/vrl.git}"

apply_line_patch() { # apply_line_patch <file> <old> <new>
  local file="$1" old="$2" new="$3"
  if grep -qF "$new" "$file"; then
    echo "   already applied: $file"
    return 0
  fi
  grep -qF "$old" "$file" || { echo "PATCH TARGET MISSING in $file: $old" >&2; exit 1; }
  python3 - "$file" "$old" "$new" <<'EOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
assert s.count(old) == 1, f"expected exactly one occurrence in {path}"
open(path, 'w').write(s.replace(old, new))
EOF
}

echo "== patch 1: tonic without rustls tls features"
apply_line_patch Cargo.toml \
  'tonic = { version = "0.11", default-features = false, features = ["transport", "codegen", "prost", "tls", "tls-roots", "gzip", "zstd"] }' \
  'tonic = { version = "0.11", default-features = false, features = ["transport", "codegen", "prost", "gzip", "zstd"] }'

echo "== patch 2: reqwest_13 optional, gated behind sinks-azure_blob"
apply_line_patch Cargo.toml \
  'reqwest_13 = { package = "reqwest", version = "0.13", default-features = false, features = ["json", "native-tls", "rustls-no-provider"] }' \
  'reqwest_13 = { package = "reqwest", version = "0.13", default-features = false, features = ["json", "native-tls", "rustls-no-provider"], optional = true }'
apply_line_patch Cargo.toml \
  'sinks-azure_blob = ["dep:azure_core", "dep:azure_identity", "dep:azure_storage_blob"]' \
  'sinks-azure_blob = ["dep:azure_core", "dep:azure_identity", "dep:azure_storage_blob", "dep:reqwest_13"]'

echo "== patch 3: vendor vrl @ ${VRL_COMMIT:0:9} without community_id (SHA-1)"
# Outside the vector checkout: a package physically inside the workspace dir
# would be claimed by the enclosing workspace. The callers bind-mount
# build/vrl-patched here.
vrl_dir="${VRL_DIR:-/work/vrl-patched}"
if [ ! -f "$vrl_dir/.patched" ] || [ "$(git -C "$vrl_dir" rev-parse HEAD 2>/dev/null)" != "$VRL_COMMIT" ]; then
  # the dir is a bind mount — clear contents, not the mountpoint
  mkdir -p "$vrl_dir"
  find "$vrl_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  git -C "$vrl_dir" init -q
  git -C "$vrl_dir" fetch -q --depth 1 "$VRL_REPO" "$VRL_COMMIT"
  git -C "$vrl_dir" checkout -q FETCH_HEAD
  [ "$(git -C "$vrl_dir" rev-parse HEAD)" = "$VRL_COMMIT" ] || { echo "vrl commit mismatch" >&2; exit 1; }
  (
    cd "$vrl_dir"
    apply_line_patch() { # local copy (function not exported through subshell cd)
      local file="$1" old="$2" new="$3"
      grep -qF "$old" "$file" || { echo "PATCH TARGET MISSING in vrl $file: $old" >&2; exit 1; }
      python3 - "$file" "$old" "$new" <<'EOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
assert s.count(old) == 1, f"expected exactly one occurrence in {path}"
open(path, 'w').write(s.replace(old, new))
EOF
    }
    apply_line_patch Cargo.toml '  "dep:community-id",
' ''
    apply_line_patch src/stdlib/mod.rs '        mod community_id;
' ''
    apply_line_patch src/stdlib/mod.rs '            self::community_id::CommunityID,
' ''
    # the function must be gone, and nothing else may reference it
    ! grep -rq 'community_id' src/stdlib/mod.rs || { echo "vrl patch incomplete" >&2; exit 1; }
  )
  touch "$vrl_dir/.patched"
else
  echo "   already applied: vendored vrl present"
fi
# lock's recorded vrl pin must match what we vendored
lock_vrl="$(awk '/^name = "vrl"/{f=1} f && /^source/{print; exit}' Cargo.lock | sed 's/.*#//; s/"//')"
if [ -n "$lock_vrl" ] && [ "$lock_vrl" != "$VRL_COMMIT" ]; then
  echo "Cargo.lock pins vrl@$lock_vrl but VRL_COMMIT=$VRL_COMMIT — update ci/pins.sh" >&2
  exit 1
fi

if ! grep -q 'patch."https://github.com/vectordotdev/vrl.git"' Cargo.toml; then
  printf '\n[patch."https://github.com/vectordotdev/vrl.git"]\nvrl = { path = "%s" }\n' "$vrl_dir" >> Cargo.toml
  echo "   [patch] section appended"
fi

echo "== patch 4: vendor headers 0.3.9 without SecWebsocketAccept (RustCrypto SHA-1)"
# `headers` is a non-optional typed-HTTP-headers dep (vector, vector-core,
# warp, hyper-proxy) that unconditionally bundles RustCrypto sha1 solely for
# its Sec-WebSocket-Accept type. No websocket component is in the feature
# set and nothing in the graph references the type (verified: warp's ws
# module is feature-gated off) — remove the module so no SHA-1
# implementation ships in the binary at all.
HEADERS_VERSION=0.3.9
HEADERS_SHA256=06683b93020a07e3dbcf5f8c0f6d40080d725bea7936fc01ad345c01b97dc270
hdr_dir="${HEADERS_DIR:-/work/headers-patched}"
# pin must agree with the lock (defense against silent version drift)
grep -A3 'name = "headers"' Cargo.lock | grep -q "checksum = \"$HEADERS_SHA256\"" \
  || { echo "Cargo.lock checksum for headers $HEADERS_VERSION != pinned — review" >&2; exit 1; }
if [ ! -f "$hdr_dir/.patched" ]; then
  mkdir -p "$hdr_dir"
  find "$hdr_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  curl -fsSL -o /tmp/headers.crate "https://static.crates.io/crates/headers/headers-${HEADERS_VERSION}.crate"
  echo "$HEADERS_SHA256  /tmp/headers.crate" | sha256sum -c - >/dev/null
  tar -xzf /tmp/headers.crate -C "$hdr_dir" --strip-components=1
  rm /tmp/headers.crate
  (
    cd "$hdr_dir"
    for target in \
      'Cargo.toml|[dependencies.sha1]
version = "0.10"
' \
      'src/lib.rs|extern crate sha1;
' \
      'src/common/mod.rs|pub use self::sec_websocket_accept::SecWebsocketAccept;
' \
      'src/common/mod.rs|mod sec_websocket_accept;
'; do
      file="${target%%|*}"; old="${target#*|}"
      python3 - "$file" "$old" <<'EOF'
import sys
path, old = sys.argv[1], sys.argv[2]
s = open(path).read()
assert s.count(old) == 1, f"expected exactly one occurrence in {path}: {old!r}"
open(path, 'w').write(s.replace(old, ''))
EOF
    done
    rm -f src/common/sec_websocket_accept.rs
    ! grep -rq 'sha1\|SecWebsocketAccept' src/ Cargo.toml || { echo "headers patch incomplete" >&2; exit 1; }
  )
  touch "$hdr_dir/.patched"
else
  echo "   already applied: vendored headers present"
fi
# vector already carries a [patch.crates-io] section (ntapi) — insert into it
if ! grep -q '^headers = { path' Cargo.toml; then
  python3 - "$hdr_dir" <<'EOF'
import sys
hdr = sys.argv[1]
s = open('Cargo.toml').read()
anchor = '[patch.crates-io]\n'
assert s.count(anchor) == 1, "expected exactly one [patch.crates-io] section"
s = s.replace(anchor, anchor + 'headers = { path = "%s" }\n' % hdr)
open('Cargo.toml', 'w').write(s)
EOF
  echo "   headers entry added to [patch.crates-io]"
fi

echo "== patches applied"
