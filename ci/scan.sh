#!/usr/bin/env bash
# Vulnerability scan (Trivy) of the built image: OS packages + the Rust
# dependency inventory embedded in the vector binary (cargo-auditable —
# trivy's rust-audit detector reads it). Scans a docker-save tarball so the
# trivy container never needs daemon access — works identically on local
# docker, GitHub runners, and GitLab docker-in-docker.
#
#   1. SARIF report, FIXABLE findings only — for GitHub Code Scanning, so
#      every alert is actionable (unfixed CVEs awaiting vendor backports
#      would otherwise dominate)
#   2. JSON report, everything — the full vulnerability inventory
#      (POA&M-style artifact for GitLab / audits / local inspection)
#   3. table to stdout + GATE: exit 1 on fixable HIGH/CRITICAL findings
#
# First-party VEX: statements in vex/openvex.json (accepted risks with
# justifications, PR-reviewed) are applied to all three outputs.
#
# Usage: scan.sh <image:tag> [output-dir]   (default output-dir: build/scan)
set -euo pipefail

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.58.2}"
image="${1:?usage: scan.sh <image:tag> [output-dir]}"
outdir="${2:-build/scan}"

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
mkdir -p "$outdir"

echo "== docker save $image"
docker save "$image" -o "$outdir/image.tar"

# first-party VEX kicks in once it has statements (trivy rejects an empty doc)
vex_args=()
if grep -q '"vulnerability"' vex/openvex.json 2>/dev/null; then
  vex_args=(--vex vex/openvex.json)
fi

run_trivy() { # scan the saved tarball; cache the vuln DB across runs
  docker run --rm \
    -v "$here:/work" -w /work \
    -v trivy-cache:/root/.cache/trivy \
    "$TRIVY_IMAGE" image --input "$outdir/image.tar" \
    ${vex_args[@]+"${vex_args[@]}"} "$@"
}

echo "== trivy: SARIF (fixable only) + JSON (full inventory) reports"
run_trivy --format sarif --output "$outdir/trivy.sarif" --ignore-unfixed --quiet
run_trivy --format json  --output "$outdir/trivy.json"  --quiet

echo "== trivy: gate — fixable HIGH/CRITICAL fail the build"
rc=0
run_trivy --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 || rc=1

rm -f "$outdir/image.tar"
if [ "$rc" -eq 0 ]; then
  echo "scan: OK — no fixable HIGH/CRITICAL findings ($outdir/trivy.{sarif,json})"
else
  echo "scan: FAIL — fixable HIGH/CRITICAL findings above ($outdir/trivy.{sarif,json})" >&2
fi
exit "$rc"
