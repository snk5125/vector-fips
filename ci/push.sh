#!/usr/bin/env bash
# Push image tags. Registry login is the CI runner's job (GH: docker/login-action,
# GitLab: docker login $CI_REGISTRY) — this script stays runner-agnostic.
# Usage: push.sh <image> <version>
# Env:   PUSH_LATEST=1 to also push :latest
set -euo pipefail

image="${1:?usage: push.sh <image> <version>}"
version="${2:?usage: push.sh <image> <version>}"

docker push "$image:$version"
if [ "${PUSH_LATEST:-}" = "1" ]; then
  docker push "$image:latest"
fi
echo "push: $image:$version${PUSH_LATEST:+ (+latest)}"
