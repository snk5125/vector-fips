#!/usr/bin/env bash
# Lint the Containerfiles (hadolint, pinned, containerized) and shell scripts
# (shellcheck when available locally; hard requirement in CI).
set -euo pipefail

HADOLINT_IMAGE="${HADOLINT_IMAGE:-hadolint/hadolint:v2.12.0}"
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
rc=0

if command -v docker >/dev/null 2>&1; then
  echo "== hadolint Containerfile Containerfile.base Containerfile.builder"
  # DL3041/DL3040-family: pinning dnf package versions is impractical against
  # UBI's rolling repos; the base image itself is digest-pinned.
  # DL3006: FROM ${BASE_IMAGE} — the ARG default is either the locally-built
  # base (bootstrap) or a digest pin maintained by workflows/base.yml.
  for cf in Containerfile Containerfile.base Containerfile.builder; do
    docker run --rm -i "$HADOLINT_IMAGE" hadolint \
      --ignore DL3041 --ignore DL3006 - < "$cf" || rc=1
  done
else
  echo "WARN: docker unavailable — skipping hadolint" >&2
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck ci/*.sh docker/entrypoint.sh"
  shellcheck --severity=warning ci/*.sh docker/entrypoint.sh || rc=1
elif [ "${CI:-}" != "" ]; then
  echo "FAIL: shellcheck required in CI" >&2; rc=1
else
  echo "WARN: shellcheck unavailable — skipping" >&2
fi

exit "$rc"
