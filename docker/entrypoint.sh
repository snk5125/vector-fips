#!/usr/bin/env bash
# Entrypoint for the FIPS-mode Vector aggregator image.
#
# FIPS is ON by default: the image ENV points Vector's statically linked
# OpenSSL at the container's validated provider (OPENSSL_CONF=
# /etc/vector/openssl-fips.cnf, OPENSSL_MODULES=/usr/lib64/ossl-modules) and
# config_diagnostics makes a missing/broken provider fail loudly.
# VECTOR_FIPS=0 opts a dev instance out (drops the OpenSSL config).
#
# All arguments are forwarded to `vector` (default CMD runs the baked
# aggregator config), so `docker run <image> validate -c <cfg>` etc. work.
set -euo pipefail

if [ "${VECTOR_FIPS:-1}" = "1" ]; then
  if [ ! -f /usr/lib64/ossl-modules/fips.so ]; then
    cat >&2 <<'EOF'
ERROR: FIPS mode requested (VECTOR_FIPS=1, the default) but the OpenSSL FIPS
provider module is missing at /usr/lib64/ossl-modules/fips.so. This image is
built from a base that ships Red Hat's validated provider — refusing to run
without it. Set VECTOR_FIPS=0 only for a non-FIPS dev instance.
EOF
    exit 1
  fi
  echo "== FIPS mode: OpenSSL providers under $OPENSSL_CONF:"
  # System openssl CLI shares the module dir + config; provider list is the
  # boot-log evidence that fips is active (validate.sh asserts it matches the
  # CMVP provenance label).
  openssl list -providers || true
else
  # Genuinely non-FIPS run (the negative validation check depends on this):
  # drop the OpenSSL config so the embedded libcrypto uses its defaults.
  unset OPENSSL_CONF
  echo "== FIPS mode disabled (VECTOR_FIPS != 1)"
fi

exec /usr/bin/vector "$@"
