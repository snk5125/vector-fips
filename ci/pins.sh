#!/usr/bin/env bash
# Single source of truth for the Vector source pin. Sourced by ci/*.sh.
# Bumping Vector = updating these three values + re-running `make audit`
# (regenerates the per-feature crypto audit) in the same commit.
export VECTOR_VERSION="0.57.0"
export VECTOR_TAG="v0.57.0"
export VECTOR_COMMIT="8832452f57afb536ea0de53a093f9fd1b669ccec"
export VECTOR_REPO="https://github.com/vectordotdev/vector.git"
# vrl is a git dependency of vector (branch = main), pinned by vector's
# Cargo.lock; we vendor + patch exactly that commit (ci/apply-source-patches.sh
# asserts the lock agrees).
export VRL_COMMIT="33fec9bddb7e75db90187f686ac3a69063882ced"
