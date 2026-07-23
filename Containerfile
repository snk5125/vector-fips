# FIPS-mode Vector aggregator.
# Base: ubi9-patched (Containerfile.base) — UBI9-minimal + latest el9 CVE
# backports, built/scanned/published on its own cadence by
# .github/workflows/base.yml, which also maintains this digest pin. It ships
# Red Hat's CMVP-validated OpenSSL FIPS provider
# (/usr/lib64/ossl-modules/fips.so).
# The vector binary is custom-compiled by ci/build-vector.sh (pinned source,
# curated FIPS feature set, forbidden-crate gate — see
# docs/removed-functionality.md) into build/artifacts/, consumed here like a
# vendor artifact. Its vendored OpenSSL 3.0.x is statically linked; at
# runtime OPENSSL_CONF + OPENSSL_MODULES point it at the CONTAINER's
# validated provider.
# Bootstrap default: the locally built base (ci/build.sh always supplies it);
# the base workflow rewrites this ARG to the published digest pin.
ARG BASE_IMAGE=vector-fips/ubi9-patched-local:local

FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN groupadd -g 1000 vector \
 && useradd -u 1000 -g vector -d /var/lib/vector -M -s /sbin/nologin vector \
 && mkdir -p /var/lib/vector \
 && chown 1000:1000 /var/lib/vector

COPY build/artifacts/vector /usr/bin/vector
# Audit evidence baked into the image: what was compiled, from what, with
# which features, and the full resolved crate graph the crypto gate saw.
COPY build/artifacts/build-manifest.json build/artifacts/cargo-tree.txt /usr/share/vector/build/
COPY config/vector/ /etc/vector/
COPY config/openssl-fips.cnf /etc/vector/openssl-fips.cnf
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/bin/vector

ENV OPENSSL_CONF=/etc/vector/openssl-fips.cnf \
    OPENSSL_MODULES=/usr/lib64/ossl-modules \
    VECTOR_FIPS=1

# --- build gates ------------------------------------------------------------
# 1. The FIPS provider activates under our config (system CLI shares the
#    module dir + libcrypto lineage with the provider package).
# 2. The custom binary runs and its OpenSSL is the vendored static build
#    (no dynamic libssl/libcrypto).
# 3. The baked config validates.
# 4. Removals are real: a VRL program calling md5() must FAIL to compile,
#    and an aws_s3 sink must be an unknown type (spot checks; the full list
#    is asserted by ci/validate.sh).
RUN openssl list -providers > /tmp/prov.txt \
 && grep -qi '^  fips' /tmp/prov.txt \
 && grep -qi '^  base' /tmp/prov.txt \
 && /usr/bin/vector --version \
 && ldd /usr/bin/vector | { ! grep -E 'libssl|libcrypto'; } \
 && /usr/bin/vector validate --no-environment /etc/vector/vector.yaml \
 && printf 'sources:\n  s: {type: demo_logs, format: json}\ntransforms:\n  t:\n    type: remap\n    inputs: [s]\n    source: |\n      .x = md5("a")\nsinks:\n  o: {type: blackhole, inputs: [t]}\n' > /tmp/md5.yaml \
 && if /usr/bin/vector validate --no-environment /tmp/md5.yaml; then echo "GATE FAIL: md5() still compiles" >&2; exit 1; fi \
 && printf 'sources:\n  s: {type: demo_logs}\nsinks:\n  o: {type: aws_s3, inputs: [s], bucket: b, region: us-east-1}\n' > /tmp/s3.yaml \
 && if /usr/bin/vector validate --no-environment /tmp/s3.yaml; then echo "GATE FAIL: aws_s3 sink still present" >&2; exit 1; fi \
 && rm -f /tmp/prov.txt /tmp/md5.yaml /tmp/s3.yaml

USER vector
WORKDIR /var/lib/vector

# 6000 vector-to-vector; 8080 http NDJSON; 24224 fluent forward;
# 8686 API (localhost healthcheck); 9598 prometheus_exporter
EXPOSE 6000 8080 24224 9598
HEALTHCHECK --interval=10s --timeout=5s --retries=6 --start-period=15s \
  CMD curl -fsS http://127.0.0.1:8686/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["-c", "/etc/vector/vector.yaml"]
