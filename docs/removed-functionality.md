# Removed functionality (relative to upstream Vector 0.57.0 GA)

Everything absent from this build, with the evidence. The method is
mechanical and reproducible: `make audit` (ci/audit-features.sh) resolves
the dependency closure of **every** upstream component feature against the
patched source and flags any that introduce crates from
[ci/forbidden-crates.txt](../ci/forbidden-crates.txt) — TLS stacks with
their own cryptography (ring, aws-lc, rustls) and pure-Rust RustCrypto
primitives, none of which are FIPS-validated. The kept set is
[ci/features-fips.txt](../ci/features-fips.txt); the same forbid list is a
hard gate on the final resolved graph at compile time (zero hits, 681
crates — the graph ships in the image at
`/usr/share/vector/build/cargo-tree.txt`), and `ci/validate.sh` asserts a
sample of removals against the shipped binary every build.

Trust chain: audit classification → compile-time gate → runtime assert.
The audit is dependency-level; it is complemented by a code-level sweep for
tonic TLS type usage (`ClientTlsConfig`/`Identity`/`Certificate`), which is
how `gcp_pubsub` was caught despite a clean dependency closure.

## Removed sources

| Source | Offending dependency chain (audit evidence) |
| --- | --- |
| `aws_s3`, `aws_sqs`, `aws_kinesis_firehose`, `aws_ecs_metrics`* | AWS SDK: `ring` (rustls), `hmac`/`sha2` (+`md-5` for S3 ETags) via `aws-sigv4` request signing |
| `dnstap` | `ring` (DNS stack DNSSEC path) |
| `gcp_pubsub` | code-level: its gRPC transport to Google is built with `tonic::transport::ClientTlsConfig`/`Identity` — tonic's **rustls** TLS stack (src/sources/gcp_pubsub.rs), not Vector's OpenSSL layer. Caught by code sweep, not `cargo tree` (dependency-clean but crypto-wrong). The REST-based `gcp` **sinks** stay (Vector's OpenSSL HTTP client + goauth/OpenSSL JWT signing). |
| `docker_logs` | `ring` (bollard registry auth stack) |
| `mongodb_metrics` | `ring`, `hmac`/`sha2`/`md-5` (MongoDB driver rustls + SCRAM auth) |
| `mqtt` | full rustls stack (`rustls` 0.22, `tokio-rustls`, `ring`) via rumqttc |
| `nats` | `ring`, `nkeys`, `ed25519-dalek`, `curve25519-dalek`, `sha2` (NATS NKeys auth is Ed25519 by design) |
| `postgresql_metrics` | `hmac`/`sha2`/`md-5` (tokio-postgres SCRAM-SHA-256 / MD5 auth) |
| `pulsar` | `ring`, `rsa`, `ecdsa`, `p256`/`p384`, `ed25519-dalek`, `hmac`/`sha2` (Pulsar auth token stack) |
| `websocket` | `sha1` — the RFC 6455 `Sec-WebSocket-Accept` handshake is RustCrypto SHA-1 (tungstenite) |
| `kubernetes_logs` — **kept**; `exec`, `file`, `journald`, `host_metrics`, ... — **kept** | (listed here to make clear the OpenSSL-TLS stack stays) |

\* `aws_ecs_metrics` and `aws_kinesis_firehose` *sources* audit CLEAN in
isolation (plain HTTP), but are excluded with the AWS family: they are
operationally inseparable from an AWS deployment whose sibling components
are removed, and keeping them would invite confusion about AWS support.
This pair is the only *policy* exclusion; everything else in this table is
a *dependency* exclusion.

## Removed sinks

| Sink | Offending dependency chain |
| --- | --- |
| `aws_s3`, `aws_sqs`, `aws_sns`, `aws_cloudwatch_logs`, `aws_cloudwatch_metrics`, `aws_kinesis_streams`, `aws_kinesis_firehose` | AWS SDK sigv4: `ring`, `hmac`, `sha2` (+`md-5` S3) |
| `azure_blob`, `azure_logs_ingestion`, `azure_monitor_logs` | `reqwest 0.13` rustls stack (azure_core HTTP transport); azure_blob additionally held the `reqwest_13` dependency that was unconditionally polluting every build (see patch 2 below) |
| `databend` | `ring` (databend-client rustls) |
| `doris` | `sha1`, `sha2`, `md-5`, `rsa`, `hmac`, `ring`, rustls stack — sqlx-mysql (MySQL `caching_sha2_password` / RSA auth exchange) |
| `greptimedb_metrics`, `greptimedb_logs` | `ring` (greptimedb-ingester gRPC TLS) |
| `mqtt` | rustls stack via rumqttc |
| `nats` | `ring`, `nkeys`, `ed25519-dalek` (NKeys) |
| `postgres` | `ring`, `hmac`/`sha2`/`md-5` (sqlx-postgres SCRAM, tls-rustls-ring) |
| `pulsar` | as the source: `rsa`, `ecdsa`, `p256/p384`, `ed25519`, `ring` |
| `webhdfs` | `md-5` (opendal content checksums) |
| `websocket`, `websocket-server` | `sha1` (RFC 6455 handshake, tungstenite) |
| `appsignal`, `chronicle`, `axiom`, `honeycomb`, `keep`, `mezmo`, ... — **kept** | (vector's own OpenSSL HTTP stack) |

## Removed shared features

| Feature | Why |
| --- | --- |
| `secrets` (AWS Secrets Manager backend) | AWS SDK: `ring`, `hmac`, `sha2` |
| `gssapi` (kafka Kerberos SASL) | never enabled (upstream's local-dev default); avoids cyrus-sasl/krb5 crypto outside the provider |

## Removed VRL functions

VRL function groups are Cargo features; the crypto and network groups are
off. Functions removed from the language (a remap program calling one fails
config validation — asserted by `ci/validate.sh`):

| Function | Reason |
| --- | --- |
| `md5`, `sha1`, `sha2`, `sha3` | RustCrypto digests (`md-5`, `sha1`, `sha2`, `sha3` crates) |
| `hmac` | RustCrypto `hmac` |
| `encrypt`, `decrypt` | RustCrypto ciphers (`aes`, `aes-siv`, `chacha20poly1305`, `cbc`, `ctr`, `cfb-mode`, `ofb`, `crypto_secretbox`) |
| `encrypt_ip`, `decrypt_ip` | `ipcrypt-rs` (AES-based IP encryption) |
| `community_id` | Zeek Community ID flow hashes are SHA-1 by definition (`community-id` → `sha1`). Lives in VRL's *base* stdlib, so it is removed by a one-function source patch of the pinned vrl commit (patch 3). |
| `dns_lookup`, `reverse_dns`, `http_request` | network group: reqwest with `rustls-tls` (`ring`) |
| `crc`, `seahash`, `xxhash` | **not crypto** — non-cryptographic checksums that upstream groups into the same `enable_crypto_functions` feature; casualties of the feature grouping, documented for transparency |
| `get_env_var`, `get_hostname`, `encode_proto`, `parse_proto`, `parse_etld`, `validate_json_schema`, `get_timezone_name`, ... — **kept** | env + system groups have no crypto |

## Source patches (all exact-match asserted at build)

1. **tonic** (workspace dep): rustls-based `tls`,`tls-roots` features removed.
   Vector performs gRPC TLS via its own OpenSSL `MaybeTlsSettings`; no code
   references `tonic::transport` TLS types. Without this, every gRPC
   component (`vector` source/sink, `opentelemetry`, `datadog_agent`, the
   API) would carry rustls.
2. **reqwest_13**: made `optional`, tied to the (excluded) `sinks-azure_blob`
   — upstream declares it unconditionally, which put the rustls 0.23 stack
   into every build regardless of features.
3. **vrl** (vendored at the Cargo.lock-pinned commit `33fec9bd…`):
   `community_id()` removed (see table above).
4. **headers 0.3.9** (vendored, checksum pinned to the lock): the
   `SecWebsocketAccept` type and its `sha1` dependency removed — a
   non-optional typed-header library that bundles SHA-1 solely for websocket
   handshakes no component in this build can perform.
5. **vector-core**: gRPC connect-info stores peer-certificate PEM bytes
   directly instead of wrapping them in `tonic::transport::Certificate`
   (that type is gated behind tonic's removed rustls `tls` feature; the
   field has no consumers in the workspace).

Cargo.lock discipline: after patching, the lock diff is gated to be
removals-only (no new packages, no version changes).

## Deliberately NOT removed

- `rustls-pemfile` (via reqwest 0.11's native-tls path): PEM **parser**, no
  cryptographic primitives. Documented in ci/forbidden-crates.txt.
- OpenSSL-backed TLS everywhere else: all kept components terminate TLS via
  the statically linked OpenSSL, whose algorithms come from the container's
  validated FIPS provider at runtime (see [fips-notes.md](fips-notes.md)).
- `kafka` (librdkafka): C library compiled against the same vendored
  OpenSSL — its TLS/SASL-SCRAM crypto routes through the provider.

## Regenerating the evidence

```bash
make audit          # per-feature classification -> build/audit/audit.tsv
make build          # compile gate: forbid-list vs final graph (fails closed)
make validate       # runtime asserts incl. removal spot-checks
```
