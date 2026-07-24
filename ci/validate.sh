#!/usr/bin/env bash
# Boot-and-assert validator for the FIPS Vector aggregator image.
#
#   1. FIPS positive: default run (FIPS on) serves TLS ingest — a handshake
#      + NDJSON POST lands in a file sink while the OpenSSL config restricts
#      algorithm fetches to fips=yes and activates only the fips+base
#      providers. This exercises the *embedded* statically-linked libcrypto
#      loading the CONTAINER's validated provider module.
#   2. Non-vacuous negative: same TLS config but OPENSSL_MODULES pointed at
#      an empty dir — the provider cannot load, so TLS must NOT work and the
#      boot must fail (config_diagnostics fail-closed). Proves assert #1
#      actually depends on the container's fips.so.
#   3. Provider provenance: runtime-active provider version exactly matches
#      the CMVP traceability label baked by the base image.
#   4. Removals are real: `vector validate` rejects configs using removed
#      VRL functions (md5, sha2, encrypt, dns_lookup) and removed components
#      (aws_s3/nats/websocket/mqtt/databend...), and accepts a kept-function
#      control config (non-vacuous).
#   5. Functional dev: VECTOR_FIPS=0 boots the baked config, healthcheck
#      passes, plain NDJSON ingest works, uid 1000, prometheus exporter up.
#
# Usage: validate.sh <image:tag>
set -euo pipefail

image="${1:?usage: validate.sh <image:tag>}"
BOOT_WAIT="${BOOT_WAIT:-60}"
rc=0

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

c1="vecfips-val-tls-$$"
c2="vecfips-val-neg-$$"
c3="vecfips-val-fn-$$"
tmp="$(mktemp -d)"
cleanup() { docker rm -f "$c1" "$c2" "$c3" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; rc=1; }

wait_running_api() { # wait_running_api <container> <max-seconds> — vector API /health
  local c="$1" max="$2" t=0
  while true; do
    docker exec "$c" curl -fsS http://127.0.0.1:8686/health >/dev/null 2>&1 && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || return 1
    t=$((t + 2)); [ "$t" -ge "$max" ] && return 1
    sleep 2
  done
}

echo "== prep: self-signed RSA-2048/SHA-256 cert + TLS overlay config"
# Generated with the IMAGE's openssl under the image's FIPS config — portable
# (host openssl may be LibreSSL without -addext) and an extra provider
# exercise. SAN required: modern verification ignores CN.
# chmod happens inside the container: the files are root-owned there, and
# the host user (CI runner) cannot chmod them afterwards.
docker run --rm --entrypoint /bin/bash -u 0 -v "$tmp:/v" "$image" -c \
  'openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
     -keyout /v/key.pem -out /v/crt.pem -subj "/CN=localhost" \
     -addext "subjectAltName=DNS:localhost" && chmod 644 /v/key.pem /v/crt.pem' >/dev/null 2>&1
[ -s "$tmp/crt.pem" ] || { echo "FAIL: cert generation in image failed" >&2; exit 1; }
cat > "$tmp/tls.yaml" <<'EOF'
api:
  enabled: true
  address: 127.0.0.1:8686
sources:
  tls_in:
    type: http_server
    address: 0.0.0.0:8443
    framing: {method: newline_delimited}
    decoding: {codec: json}
    tls:
      enabled: true
      crt_file: /validate/crt.pem
      key_file: /validate/key.pem
sinks:
  out:
    type: file
    inputs: [tls_in]
    path: /var/lib/vector/validate-out.ndjson
    encoding: {codec: json}
EOF
chmod 644 "$tmp/tls.yaml"   # pem perms handled in-container (root-owned)

echo "== 1. FIPS positive: TLS ingest through the container's validated provider"
docker rm -f "$c1" >/dev/null 2>&1 || true
docker run -d --name "$c1" -v "$tmp:/validate:ro" "$image" -c /validate/tls.yaml >/dev/null
if ! wait_running_api "$c1" "$BOOT_WAIT"; then
  fail "FIPS TLS instance did not become healthy — last 30 log lines:"
  docker logs "$c1" 2>&1 | tail -30 >&2
else
  logs="$(docker logs "$c1" 2>&1)"
  grep -q 'FIPS mode' <<<"$logs" || fail "entrypoint FIPS banner missing"
  grep -qi 'OpenSSL FIPS Provider' <<<"$logs" || fail "provider list in boot log missing fips provider"
  ingest_ok=0
  for _ in $(seq 1 15); do
    if docker exec "$c1" curl -fsS --cacert /validate/crt.pem \
         -XPOST https://localhost:8443 -d '{"marker":"fips-tls-smoke"}' >/dev/null 2>&1; then
      ingest_ok=1; break
    fi
    sleep 2
  done
  if [ "$ingest_ok" != "1" ]; then
    fail "TLS NDJSON POST to :8443 did not succeed — last 30 log lines:"
    docker logs "$c1" 2>&1 | tail -30 >&2
  else
    sunk=0
    for _ in $(seq 1 15); do
      if docker exec "$c1" sh -c 'grep -q fips-tls-smoke /var/lib/vector/validate-out.ndjson' 2>/dev/null; then
        sunk=1; break
      fi
      sleep 2
    done
    [ "$sunk" = "1" ] && echo "   OK: TLS handshake + ingest + file sink under fips-only providers" \
                      || fail "event did not reach the file sink"
  fi
  # --- 3. provider provenance vs CMVP label ---
  pv="$(docker exec "$c1" sh -c \
        "openssl list -providers 2>/dev/null | grep -A2 '^  fips' | awk '/version:/ {print \$2}'" || true)"
  pinned_pv="$(docker inspect -f '{{index .Config.Labels "io.grimoire.fips.provider.module-version"}}' "$image" 2>/dev/null || true)"
  cert="$(docker inspect -f '{{index .Config.Labels "io.grimoire.fips.cmvp.certificate"}}' "$image" 2>/dev/null || true)"
  if [ -z "$pv" ]; then
    fail "openssl fips provider not active in the running container"
  elif [ -n "$pinned_pv" ] && [ "$pv" != "$pinned_pv" ]; then
    fail "active fips provider $pv != pinned $pinned_pv — CMVP cert #$cert traceability broken"
  else
    echo "   OK: fips provider $pv (pinned; CMVP cert #${cert:-unlabeled})"
  fi
  [ "$(docker exec "$c1" id -u)" = "1000" ] || fail "container not running as uid 1000"
fi
docker rm -f "$c1" >/dev/null 2>&1 || true

echo "== 2. non-vacuous negative: provider dir empty -> TLS must fail"
docker rm -f "$c2" >/dev/null 2>&1 || true
docker run -d --name "$c2" -v "$tmp:/validate:ro" -e OPENSSL_MODULES=/tmp/no-modules \
  "$image" -c /validate/tls.yaml >/dev/null
neg_ok=1
for _ in $(seq 1 10); do
  if docker exec "$c2" curl -fsS --cacert /validate/crt.pem \
       -XPOST https://localhost:8443 -d '{"marker":"must-not-work"}' >/dev/null 2>&1; then
    neg_ok=0; break
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$c2" 2>/dev/null)" != "true" ] && break
  sleep 2
done
if [ "$neg_ok" = "1" ]; then
  echo "   OK: TLS unusable without the container's provider module (fail-closed)"
else
  fail "TLS ingest SUCCEEDED with OPENSSL_MODULES pointing at an empty dir — FIPS assert is vacuous"
fi
docker rm -f "$c2" >/dev/null 2>&1 || true

echo "== 4. removals are real (vector validate)"
run_validate() { # run_validate <config-file>
  docker run --rm -v "$tmp:/validate:ro" "$image" validate --no-environment "/validate/$1" >/dev/null 2>&1
}
# kept-function control keeps the negative checks honest
cat > "$tmp/control.yaml" <<'EOF'
sources:
  s: {type: demo_logs, format: json}
transforms:
  t:
    type: remap
    inputs: [s]
    source: |
      .h = get_hostname!()
      .p = parse_json!("{\"a\":1}")
sinks:
  o: {type: blackhole, inputs: [t]}
EOF
if run_validate control.yaml; then
  echo "   OK: control config (kept VRL functions) validates"
else
  fail "control config with kept VRL functions failed validation"
fi
for fn in 'md5("a")' 'sha2("a")' 'encrypt("a", "AES-128-CBC", "0123456789012345", iv: "0123456789012345")' 'hmac("a","b")' 'dns_lookup("x")'; do
  cat > "$tmp/bad-fn.yaml" <<EOF
sources:
  s: {type: demo_logs, format: json}
transforms:
  t:
    type: remap
    inputs: [s]
    source: |
      .x = ${fn}
sinks:
  o: {type: blackhole, inputs: [t]}
EOF
  if run_validate bad-fn.yaml; then
    fail "removed VRL function still compiles: ${fn%%(*}"
  else
    echo "   OK: VRL ${fn%%(*}() rejected"
  fi
done
for comp in 'sinks:\n  o: {type: aws_s3, inputs: [s], bucket: b, region: r}' \
            'sinks:\n  o: {type: nats, inputs: [s], url: "nats://x", subject: s}' \
            'sinks:\n  o: {type: websocket, inputs: [s], uri: "ws://x"}' \
            'sinks:\n  o: {type: mqtt, inputs: [s], host: h, topic: t}' \
            'sinks:\n  o: {type: databend, inputs: [s], endpoint: "http://x", table: t}'; do
  printf 'sources:\n  s: {type: demo_logs, format: json}\n%b\n' "$comp" > "$tmp/bad-comp.yaml"
  ctype="$(sed -n 's/.*type: \([a-z_0-9]*\).*/\1/p' <<<"$comp" | head -1)"
  if run_validate bad-comp.yaml; then
    fail "removed component still present: $ctype"
  else
    echo "   OK: component '$ctype' rejected"
  fi
done

echo "== 5. functional dev instance (VECTOR_FIPS=0, baked config)"
docker rm -f "$c3" >/dev/null 2>&1 || true
docker run -d --name "$c3" -e VECTOR_FIPS=0 "$image" >/dev/null
if ! wait_running_api "$c3" "$BOOT_WAIT"; then
  fail "health probe (non-FIPS dev) — last 30 log lines:"
  docker logs "$c3" 2>&1 | tail -30 >&2
else
  dev_ok=1
  # capture-then-grep: `docker logs | grep -q` + pipefail = SIGPIPE race
  dev_logs="$(docker logs "$c3" 2>&1)"
  if ! grep -q 'FIPS mode disabled' <<<"$dev_logs"; then
    fail "entrypoint did not report FIPS disabled — first 5 log lines:"
    head -5 <<<"$dev_logs" >&2
    dev_ok=0
  fi
  ingest_ok=0
  for _ in $(seq 1 15); do
    if docker exec "$c3" curl -fsS -XPOST http://localhost:8080 -d '{"smoke":"plain"}' >/dev/null 2>&1; then
      ingest_ok=1; break
    fi
    sleep 2
  done
  [ "$ingest_ok" = "1" ] || { fail "plain NDJSON ingest smoke on :8080"; dev_ok=0; }
  metrics_ok=0
  for _ in $(seq 1 15); do  # exporter serves after the first internal_metrics scrape flush
    metrics_body="$(docker exec "$c3" curl -fsS http://localhost:9598/metrics 2>/dev/null || true)"
    if grep -q vector_ <<<"$metrics_body"; then
      metrics_ok=1; break
    fi
    sleep 2
  done
  if [ "$metrics_ok" != "1" ]; then
    fail "prometheus_exporter :9598 not serving internal metrics — exporter-related logs:"
    docker logs "$c3" 2>&1 | grep -iE 'prometheus|exporter|9598|error|warn' | tail -10 >&2
    docker exec "$c3" curl -sS -v http://localhost:9598/metrics 2>&1 | tail -8 >&2
    dev_ok=0
  fi
  [ "$dev_ok" = "1" ] && echo "   OK: dev instance healthy, ingest + metrics up"
fi
docker rm -f "$c3" >/dev/null 2>&1 || true

if [ "$rc" -eq 0 ]; then echo "OK: $image passed validation"; fi
exit "$rc"
