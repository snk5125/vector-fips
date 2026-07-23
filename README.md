# vector-fips

FIPS-mode **Vector aggregator** container image: Red Hat UBI9-minimal
(CMVP-validated OpenSSL FIPS provider) + a **custom-compiled Vector 0.57.0**
whose sources, sinks, and VRL functions that depend on non-FIPS crypto
libraries (ring, aws-lc, rustls, RustCrypto) are removed at compile time —
each removal verified by an automated dependency audit and documented in
[docs/removed-functionality.md](docs/removed-functionality.md).

Vector publishes no FIPS build: its GA binaries statically link OpenSSL and
bundle rustls/ring in several components, and the full VRL stdlib ships
RustCrypto-based `md5()`/`sha*()`/`encrypt()`. This image rebuilds Vector so
the only cryptography reachable at runtime is OpenSSL's — and points the
statically linked OpenSSL 3.0.x at the **container's** validated FIPS
provider (`/usr/lib64/ossl-modules/fips.so`) via `OPENSSL_CONF` +
`OPENSSL_MODULES`, with `default_properties = fips=yes` so nothing can fall
back to non-approved implementations.

## Quick start

```bash
make build         # compile pinned vector (features audit-gated) + docker build
make validate      # boot + FIPS asserts (TLS-through-provider, fail-closed,
                   #   provenance label match, removals-are-real)
make scan          # trivy: OS packages + rust deps (cargo-auditable); gate
make run           # dev profile: FIPS off -> localhost:8080 NDJSON in
make audit         # regenerate the per-feature crypto dependency audit
```

Ports: `6000` vector-to-vector in, `8080` http NDJSON in, `24224` fluent
forward in, `9598` prometheus_exporter, `8686` API (localhost healthcheck).

## How FIPS is wired

- The base ships Red Hat's separately-packaged, CMVP-certificate-traced FIPS
  provider (`openssl-fips-provider-so`, pinned + gated in
  [Containerfile.base](Containerfile.base)).
- The custom binary statically links vendored OpenSSL **3.0.x** (same branch
  as the validated 3.0.7 provider) and is a dynamic glibc executable, so its
  embedded libcrypto can `dlopen` the container's provider.
- `OPENSSL_CONF=/etc/vector/openssl-fips.cnf` activates **only** the `fips`
  + `base` providers, requires `fips=yes` algorithm properties, and sets
  `config_diagnostics` (fail-closed). `OPENSSL_MODULES=
  /usr/lib64/ossl-modules` makes the provider come from the container, not
  the binary.
- `ci/validate.sh` proves it end-to-end every build: a TLS handshake +
  ingest succeeds under fips-only providers, and the same config with the
  provider directory emptied **must fail** (the assert is non-vacuous).
- `VECTOR_FIPS=0` opts a dev instance out (entrypoint drops the OpenSSL
  config).

## What was removed (and how we know)

`make audit` resolves the dependency closure of **every** upstream component
feature and flags any that introduce crates from
[ci/forbidden-crates.txt](ci/forbidden-crates.txt). The kept set lives in
[ci/features-fips.txt](ci/features-fips.txt); the same forbid-list is a hard
compile gate, and `ci/validate.sh` asserts removed components/functions are
really gone from the shipped binary. Headlines:

- **Removed sources/sinks**: all `aws_*` (AWS SDK → rustls + RustCrypto
  sigv4), `nats` (ring + ed25519), `mongodb_metrics` (rustls), `mqtt`
  (rustls), `websocket`/`websocket-server` (RustCrypto SHA-1 handshake),
  `databend` (rustls), `postgres` sink + `greptimedb`/`pulsar`/`webhdfs`/
  `azure_*`/`chronicle`/`appsignal` (see the full table with dependency
  evidence in docs/removed-functionality.md).
- **Removed VRL functions**: `md5`, `sha1`, `sha2`, `sha3`, `hmac`,
  `encrypt`, `decrypt`, `encrypt_ip`, `decrypt_ip` (+ non-crypto riders in
  the same feature group: `crc`, `seahash`, `xxhash`), and the network group
  `dns_lookup`, `reverse_dns`, `http_request` (rustls-based reqwest).
- **Kept**: the OpenSSL-TLS component stack (http, syslog, socket, kafka,
  fluent, datadog, opentelemetry, elasticsearch, loki, gRPC vector-to-vector
  ...), all transforms, VRL base + env + system function groups.

## Patched-base pipeline

The app image builds `FROM` a pre-patched base, `ubi9-patched`
([Containerfile.base](Containerfile.base)): UBI9-minimal + Red Hat's latest
el9 CVE backports + the (two-package) runtime set. The
[base workflow](.github/workflows/base.yml) rebuilds it weekly (and on
dispatch): build → trivy scan gate → publish `ubi9-patched:<date>` → bump
the digest pin → rebuild, validate, scan, and push the app against it — so
CVE patching runs on Red Hat's cadence, not yours. arm64 dev builds
self-build an equivalent local base automatically.

## Vulnerability scanning

`ci/scan.sh` (every push + weekly): OS packages **and** the Rust dependency
inventory (the binary is built with `cargo auditable`, so trivy reads the
exact crate graph out of the shipped executable). SARIF (fixable-only → 
GitHub Code Scanning: every alert actionable) + JSON (full inventory,
POA&M-style artifact) + hard gate on fixable HIGH/CRITICAL. Accepted-risk
suppressions are PR-reviewed OpenVEX statements in [vex/](vex/README.md),
never UI dismissals.

## Auditability chain

1. Source pin: tag + commit sha verified at clone ([ci/pins.sh](ci/pins.sh)).
2. Toolchain: rustup + rustc 1.95.0 + protoc sha256-pinned
   ([Containerfile.builder](Containerfile.builder)).
3. One patch, exact-match asserted: tonic's unused rustls `tls` features
   dropped (Cargo.lock diff gated to removals-only).
4. Feature set + forbid-list compile gate; resolved crate graph and build
   manifest shipped **in the image** (`/usr/share/vector/build/`).
5. Boot-and-assert validation incl. negative controls; CMVP provenance
   labels asserted against the runtime-active provider.

## Limitations & compliance caveats

Details in [docs/fips-notes.md](docs/fips-notes.md). Headlines:

- **Host kernel**: formal FIPS 140-3 posture requires the host to run
  `fips=1`; the image activates the validated provider regardless, but the
  host is part of any real compliance boundary.
- The provider is Red Hat's patched rebuild of the certified module
  (certificate lineage documented and pinned; a provider bump fails the
  weekly base build until reviewed).
- Non-crypto hash VRL functions (`crc`, `xxhash`, `seahash`) are casualties
  of upstream's feature grouping, not FIPS policy.
- Vector's internal UUIDs/randomness are not FIPS-DRBG-sourced (not a
  cryptographic service; documented for assessors).

## Layout

```
Containerfile            ubi9-patched base + custom vector + FIPS wiring & gates
Containerfile.base       UBI9-minimal + el9 CVE backports (weekly, digest-pinned)
Containerfile.builder    UBI9 + pinned rust/protoc — compiles the custom binary
ci/                      build-vector / build / lint / validate / scan / audit / push
ci/features-fips.txt     curated component allowlist (audit-derived)
ci/forbidden-crates.txt  the non-FIPS crypto crate list (audit + compile gate)
config/                  baked aggregator config + openssl-fips.cnf
docker/entrypoint.sh     FIPS fail-closed wiring, VECTOR_FIPS=0 opt-out
docs/                    fips-notes, packages, removed-functionality
.github/workflows/       GitHub CI (thin, calls ci/*.sh); .gitlab-ci.yml same
```
