# Package justifications

Every package in the runtime image exists for a documented reason — and so
does every package deliberately left out. Modeled on DISA container-hardening
practice (same discipline as the sibling `aggregator-fips` repo). Keep this
file in sync with `Containerfile.base`.

Vector is a single self-contained Rust binary, so the runtime package set is
smaller than a typical vendor-tarball image: no interpreter, no pack
manager, no shell tooling beyond what the base ships.

## Explicitly installed (Containerfile.base)

| Package | Justification |
| --- | --- |
| `openssl` | CLI used by the build gates, `ci/validate.sh`, and the entrypoint's boot-log evidence to assert the FIPS provider loads and to print the active provider list. The `openssl-libs` it fronts also hosts `/usr/lib64/ossl-modules` — the module directory the *embedded* libcrypto loads the FIPS provider from. |
| `shadow-utils` | `groupadd`/`useradd` create the unprivileged `vector` user (uid/gid 1000) at build time. |

## Inherited from the base / hard dependencies (notable)

| Package | Justification |
| --- | --- |
| `openssl-fips-provider-so` | Red Hat's frozen, CMVP-validated OpenSSL FIPS module (`fips.so`) — the cryptographic heart of the image. Loaded at runtime by Vector's statically linked OpenSSL via `OPENSSL_MODULES`. Exact build pinned and certificate-traced; see [fips-notes.md](fips-notes.md). |
| `openssl-libs` | In the UBI9-minimal base. Serves the system `openssl` CLI and owns the provider module directory; Vector itself does **not** link it (vendored static OpenSSL — asserted by a build gate). |
| `curl-minimal` / `libcurl-minimal` | In the UBI9-minimal base. Used by the image HEALTHCHECK (`/health` on the local API) and validation smoke tests. |
| `bash` | In the base. The entrypoint is a bash script. |
| `ca-certificates` | In the base. Vector makes outbound TLS connections to user-configured sinks (Elasticsearch, Loki, Kafka, OTLP, ...); certificate validation needs the system CA bundle. |
| `glibc`, `libgcc` | Runtime link dependencies of the Rust binary (dynamic glibc executable so the embedded libcrypto can `dlopen` the FIPS provider). |

## Deliberately absent

| Package | Why not |
| --- | --- |
| `git-core` | Vector has no config-versioning feature that shells out to git (that need was Cribl-specific in the sibling image). |
| `tar`, `gzip`, `findutils` | No runtime pack/bundle extraction and no scripts that need them; Vector's own compressions are compiled in. |
| `libstdc++` | Not needed: Vector is pure Rust + C deps built statically (jemalloc, librdkafka, zstd); the C++-needing paths are build-time only. If a future component needs it, add with justification here. |
| `iproute`, `procps-ng`, editors, `jq` | Operator diagnostics belong in an ephemeral debug sidecar, not the shipped runtime surface. |

## Change discipline

Adding a package = adding CVE surface an assessor will ask about. Any change
to the install line in `Containerfile.base` must update this table in the
same commit, with the runtime reason (not "convenient for debugging") stated.
