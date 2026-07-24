# Build environment for compiling the custom Vector binary.
# UBI9 (full) so the binary links against RHEL 9 glibc (2.34) — building on a
# newer-glibc distro would emit symbols the ubi9-patched runtime cannot
# resolve. This image never ships; ci/build-vector.sh runs it with the source,
# cargo home, and target dir bind-mounted (the multi-GB build tree stays out
# of image layers).
FROM registry.access.redhat.com/ubi9/ubi:9.5@sha256:d07a5e080b8a9b3624d3c9cfbfada9a6baacd8e6d4065118f0e80c71ad518044

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# gcc/g++/make: rustc linking + C deps (jemalloc, zstd, librdkafka).
# cmake: librdkafka (rdkafka-sys). perl + modules: openssl-src's Configure
# (the vendored, statically linked OpenSSL 3.0.x build). git: cargo git
# dependency (vrl) + source clone. unzip: protoc release zip.
# clang-libs + clang-resource-filesystem: libclang and its builtin headers
# (stddef.h & co) for bindgen (zstd-sys) — deliberately NOT the full clang
# frontend, which drags in gcc-toolset.
RUN dnf install -y --setopt=install_weak_deps=0 \
      gcc gcc-c++ make cmake perl perl-FindBin perl-IPC-Cmd perl-File-Compare perl-File-Copy \
      git-core unzip clang-libs clang-resource-filesystem \
 && dnf clean all

# --- pinned rustup + toolchain (matches upstream rust-toolchain.toml) -------
ARG RUSTUP_VERSION=1.28.2
ARG RUST_VERSION=1.95.0
ARG RUSTUP_SHA256_AMD64=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
ARG RUSTUP_SHA256_ARM64=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN arch="$(uname -m)" \
 && case "$arch" in \
      x86_64)  target=x86_64-unknown-linux-gnu;  sha="$RUSTUP_SHA256_AMD64" ;; \
      aarch64) target=aarch64-unknown-linux-gnu; sha="$RUSTUP_SHA256_ARM64" ;; \
      *) echo "unsupported arch $arch" >&2; exit 2 ;; \
    esac \
 && curl -fsSL -o /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${target}/rustup-init" \
 && echo "${sha}  /tmp/rustup-init" | sha256sum -c - \
 && chmod +x /tmp/rustup-init \
 && /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION" \
 && rm /tmp/rustup-init \
 && /opt/cargo/bin/rustc --version

# --- pinned protoc (vector's build.rs / tonic-build requires the binary) ----
ARG PROTOC_VERSION=29.3
ARG PROTOC_SHA256_AMD64=3e866620c5be27664f3d2fa2d656b5f3e09b5152b42f1bedbf427b333e90021a
ARG PROTOC_SHA256_ARM64=6427349140e01f06e049e707a58709a4f221ae73ab9a0425bc4a00c8d0e1ab32
RUN arch="$(uname -m)" \
 && case "$arch" in \
      x86_64)  pa=x86_64;  sha="$PROTOC_SHA256_AMD64" ;; \
      aarch64) pa=aarch_64; sha="$PROTOC_SHA256_ARM64" ;; \
      *) echo "unsupported arch $arch" >&2; exit 2 ;; \
    esac \
 && curl -fsSL -o /tmp/protoc.zip "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-${pa}.zip" \
 && echo "${sha}  /tmp/protoc.zip" | sha256sum -c - \
 && unzip -q /tmp/protoc.zip -d /usr/local bin/protoc 'include/*' \
 && rm /tmp/protoc.zip \
 && protoc --version

ENV PATH=/opt/cargo/bin:$PATH \
    RUSTUP_TOOLCHAIN=1.95.0

# cargo-auditable embeds the exact resolved dependency list into the binary
# (rust-audit format) — trivy reads it, so the vulnerability scan covers the
# Rust dependency inventory, not just OS packages.
ARG CARGO_AUDITABLE_VERSION=0.7.5
RUN cargo install cargo-auditable --locked --version "${CARGO_AUDITABLE_VERSION}" \
 && cargo auditable --version \
 && rm -rf /opt/cargo/registry

WORKDIR /work
