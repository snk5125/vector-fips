# vector-fips — FIPS-mode Vector aggregator image (design)

Date: 2026-07-23. Status: approved for implementation (autonomous session;
requirements taken from the user's request verbatim + conventions inherited
from the sibling `aggregator-fips` repo, which is the reviewed precedent for
this pattern).

## Goal

An auditable container image that runs a **Vector aggregator** in FIPS mode:

1. A **custom-compiled Vector binary** with every source, sink, and VRL
   function that is *confirmed* to depend on non-FIPS-validated crypto
   libraries (ring, aws-lc, rustls, RustCrypto primitives) removed at compile
   time via Cargo features — each removal documented.
2. Built on a **patched UBI9 base** whose OpenSSL FIPS provider is Red Hat's
   NIST CMVP-validated module (`openssl-fips-provider-so`), with certificate
   traceability pinned and gated exactly as in `aggregator-fips`.
3. Vector's **statically linked OpenSSL** (vendored `openssl-src` 3.0.x)
   configured at runtime to load the *container's* validated FIPS provider
   from `/usr/lib64/ossl-modules` via `OPENSSL_CONF` + `OPENSSL_MODULES`.
4. Automated build, patching (weekly base refresh), vulnerability scanning
   (Trivy: SARIF fixable-only + JSON full inventory + fixable-HIGH/CRITICAL
   gate), OpenVEX accepted-risk mechanism, and boot-and-assert validation.

## Non-goals

- Host-kernel FIPS posture (documented caveat, as in aggregator-fips).
- Windows/macOS targets. CI/prod arch is amd64; arm64 is local dev.
- Distributed control plane (Vector has none; the aggregator is standalone).

## Key technical facts (verified during design)

- Pin: **Vector v0.57.0** (tag object `365b7c37…`, commit
  `8832452f57afb536ea0de53a093f9fd1b669ccec`, released 2026-07-14).
  Rust toolchain pinned by upstream `rust-toolchain.toml` = **1.95**.
- Vector links OpenSSL **statically** via `openssl = { features=["vendored"] }`
  → `openssl-src = "300"` (OpenSSL 3.0.x branch — same branch as Red Hat's
  validated 3.0.7 provider). A glibc-dynamic executable with static libcrypto
  **can** dlopen provider modules; `OPENSSL_CONF`/`OPENSSL_MODULES` are
  honored by the embedded libcrypto. Fallback plan B if the provider refuses
  to load under vendored libcrypto: build with `OPENSSL_NO_VENDOR=1` against
  UBI9 `openssl-devel` (dynamic link to the validated stack) and document.
- Upstream default build enables `vrl/stdlib` = **all** VRL functions. VRL
  (pinned by Vector's Cargo.lock at `33fec9bd…`, v0.33.1) gates function
  groups: `enable_crypto_functions` (RustCrypto: md-5, sha1/2/3, hmac, aes,
  chacha20poly1305, …) and `enable_network_functions` (reqwest with
  **rustls-tls** → ring). Both groups are **excluded**; `stdlib-base` +
  `enable_env_functions` + `enable_system_functions` are kept.
- Workspace `tonic` 0.11 declares rustls-based `tls`,`tls-roots` features;
  Vector terminates gRPC TLS itself via its OpenSSL `MaybeTlsSettings` (no
  `tonic::transport` TLS types referenced in `src/`). The build **patches
  those two features off** so gRPC components (vector source/sink, OTLP,
  datadog_agent, API) stay in without rustls.
- Component classification is produced by an automated **per-feature
  `cargo tree` audit** against a forbidden-crate list; the same check runs as
  a hard **build gate** on the final feature set. Known-forbidden stacks:
  all `aws-*` (aws-smithy rustls + aws-sigv4 RustCrypto), `nats` (ring,
  nkeys), `mongodb` (rustls), `mqtt` (rumqttc/rustls), `databend` (rustls),
  `sinks-postgres` (sqlx rustls-ring), `websocket`/`websocket-server`
  (tungstenite: RustCrypto SHA-1 handshake), `secrets` (AWS SDK),
  `vrl-functions-network`, `vrl-functions-crypto`.

## Architecture

Mirror of `aggregator-fips` (two Containerfiles, thin CI shells, make-driven):

- `Containerfile.base` — UBI9-minimal digest-pinned → `microdnf upgrade`
  (el9 CVE backports) → package set (`openssl`, `shadow-utils` only) → FIPS
  provider provenance gate (exact `openssl-fips-provider-so` NVR + embedded
  module version string) → CMVP labels. Published weekly as
  `ubi9-patched:<date>`; app consumes a digest pin.
- `Containerfile` — two custom stages:
  - **builder**: UBI9 (full) + pinned rustup 1.95 + gcc/g++/cmake/make/perl +
    sha256-pinned `protoc`. Clones vector at the pinned tag, asserts the
    commit sha, applies the tonic feature patch, `cargo build --release
    --locked --no-default-features --features "$(curated list)"`. Gates:
    resolved-graph forbidden-crate scan; `ldd` shows no dynamic
    libssl/libcrypto; build manifest (versions, features, sha) written next
    to the binary.
  - **runtime**: `FROM ubi9-patched` + `vector` user (uid 1000) + binary +
    baked aggregator config + `/etc/vector/openssl-fips.cnf` (includes
    `/etc/pki/tls/fips_local.cnf` `[fips_sect]`, activates `fips` + `base`
    providers, `default_properties = fips=yes`, `config_diagnostics = 1`) +
    entrypoint. Build gate: system openssl CLI under that conf lists the
    fips provider active; `vector validate` passes on the baked config with
    the FIPS env set.
- Runtime env: `OPENSSL_CONF=/etc/vector/openssl-fips.cnf`,
  `OPENSSL_MODULES=/usr/lib64/ossl-modules`, `VECTOR_FIPS=1`. Entrypoint:
  `VECTOR_FIPS=0` (dev) unsets the OpenSSL config; otherwise fail-closed —
  a missing/broken provider makes libcrypto init fail loudly
  (`config_diagnostics`), and validation asserts this.
- Baked config (`config/vector/vector.yaml`): sources `vector` (:6000),
  `http_server` NDJSON (:8080), `fluent` (:24224), `internal_metrics`;
  sinks `blackhole` (routes default traffic) + `prometheus_exporter`
  (:9598); `api.enabled` (:8686) for HEALTHCHECK via curl. Real deployments
  overlay `/etc/vector/` or set `VECTOR_CONFIG_DIR`.

## Validation (ci/validate.sh — the test suite)

1. **FIPS positive**: default run; TLS-enabled `http_server` with a cert
   generated at validate time; event POSTed over TLS 1.2/1.3 arrives at a
   file sink — proves the *embedded* libcrypto performed the handshake with
   only `fips`+`base` providers active (`default_properties = fips=yes`).
2. **Non-vacuous negative**: same but `OPENSSL_MODULES=/nonexistent` — TLS
   (and startup under config_diagnostics) must fail.
3. **Provider provenance**: runtime-active provider version ==
   `io.grimoire.fips.provider.module-version` label (CMVP cert traceability).
4. **Removal asserts**: `vector validate` rejects configs using `md5()` VRL,
   an `aws_s3` sink, and a `nats` source (undefined function / unknown
   component) — proves removals are real, not cosmetic.
5. **Functional**: uid 1000, `/health` via API, plain NDJSON ingest smoke,
   `VECTOR_FIPS=0` dev mode boots without the OpenSSL conf.

## Docs

- `docs/removed-functionality.md` — every component/function absent relative
  to upstream's default GA build, with the *confirmed* offending dependency
  chain (from the audit) or the profile rationale; generated data from
  `ci/audit-features.sh` output, curated by hand.
- `docs/fips-notes.md` — provider lineage (inherited pattern), static-OpenSSL
  + external-provider mechanics, caveats (host kernel, EMS check, RNG note).
- `docs/packages.md` — per-package justification (present and absent).

## Risks

- **R1**: RH fips.so may refuse to load under vendored upstream libcrypto →
  Plan B: dynamic link (`OPENSSL_NO_VENDOR`), documented deviation.
- **R2**: tonic feature patch may break compile → fall back to keeping
  `tls` features with a documented, gated exception (rustls present but
  unreachable: no code path configures tonic TLS), or drop gRPC components.
- **R3**: 8 GB docker VM may OOM on LTO → tune codegen/jobs; CI (GH runners)
  unaffected.
