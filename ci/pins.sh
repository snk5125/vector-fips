#!/usr/bin/env bash
# Single source of truth for the Vector source pin. Sourced by ci/*.sh.
# Bumping Vector = updating these three values + re-running `make audit`
# (regenerates the per-feature crypto audit) in the same commit.
export VECTOR_VERSION="0.57.0"
export VECTOR_TAG="v0.57.0"
export VECTOR_COMMIT="8832452f57afb536ea0de53a093f9fd1b669ccec"
export VECTOR_REPO="https://github.com/vectordotdev/vector.git"
