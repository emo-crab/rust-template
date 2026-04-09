ARG TARGETPLATFORM
ARG BUILDPLATFORM
FROM --platform=${TARGETPLATFORM:-linux/amd64} rust:latest AS builder
ARG TARGETPLATFORM
ARG BUILDPLATFORM
RUN echo "Build info -> BUILDPLATFORM=${BUILDPLATFORM}, TARGETPLATFORM=${TARGETPLATFORM}"
WORKDIR /usr/src/emo
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    xz-utils lz4 libc6-dev \
    musl-tools patchelf build-essential zlib1g-dev \
    ca-certificates curl git pkg-config libssl-dev lld \
    protobuf-compiler flatbuffers-compiler; \
    rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    if [ "${TARGETPLATFORM:-linux/amd64}" = "linux/arm64" ]; then \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu; \
    rm -rf /var/lib/apt/lists/*; \
    fi

# Add Rust targets based on TARGETPLATFORM
RUN set -eux; \
    case "${TARGETPLATFORM:-linux/amd64}" in \
    linux/amd64) rustup target add x86_64-unknown-linux-gnu ;; \
    linux/arm64) rustup target add aarch64-unknown-linux-gnu ;; \
    *) echo "Unsupported TARGETPLATFORM=${TARGETPLATFORM}" >&2; exit 1 ;; \
    esac

# Cross-compilation environment (used only when targeting aarch64)
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
ENV CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc
ENV CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
# Layered copy to maximize caching:
# 1) top-level manifests
#为了命中docker构建缓存，先拷贝这几个文件进去
COPY Cargo.toml Cargo.lock ./
COPY .cargo .cargo
# 2) workspace member manifests (adjust if workspace layout changes)
COPY crates/*/Cargo.toml crates/
# Pre-fetch dependencies for better caching
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo fetch --locked || true
# 3) copy full sources (this is the main cache invalidation point)
COPY . .
# Cargo build configuration for lean release artifacts
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true \
    CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
    CARGO_INCREMENTAL=0 \
    CARGO_PROFILE_RELEASE_DEBUG=false \
    CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO=off \
    CARGO_PROFILE_RELEASE_STRIP=symbols

# Generate protobuf/flatbuffers code (uses protoc/flatc from distro)
#RUN --mount=type=cache,target=/usr/local/cargo/registry \
#    --mount=type=cache,target=/usr/local/cargo/git \
#    --mount=type=cache,target=/usr/src/emo/target \
#    cargo run --bin gproto
# `ARG`/`ENV` pair is a workaround for `docker build` backward-compatibility.
#
# https://github.com/docker/buildx/issues/510
# Build emo (target depends on TARGETPLATFORM)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/usr/src/emo/target \
    set -eux; \
    case "${TARGETPLATFORM:-linux/amd64}" in \
    linux/amd64) \
    echo "Building for x86_64-unknown-linux-gnu"; \
    cargo build --manifest-path=crates/template/Cargo.toml --release --locked --target x86_64-unknown-linux-gnu --bin template-worker -j "$(nproc)"; \
    install -m 0755 target/x86_64-unknown-linux-gnu/release/template-worker /usr/local/bin/template-worker \
    ;; \
    linux/arm64) \
    echo "Building for aarch64-unknown-linux-gnu"; \
    cargo build --manifest-path=crates/template/Cargo.toml --release --locked --target aarch64-unknown-linux-gnu --bin template-worker -j "$(nproc)"; \
    install -m 0755 target/aarch64-unknown-linux-gnu/release/template-worker /usr/local/bin/template-worker \
    ;; \
    *) \
    echo "Unsupported TARGETPLATFORM=${TARGETPLATFORM}" >&2; exit 1 \
    ;; \
    esac


# -----------------------------
# Runtime stage (Ubuntu minimal)
# -----------------------------
# Use any runner as you want
# But beware that some images have old glibc which makes rust unhappy
FROM --platform=${TARGETPLATFORM:-linux/amd64} gitea.waterdroplab.io/kali-team/debian-base:dev
LABEL maintainer="root@kali-team.cn"
LABEL version="1.0"
LABEL description="这是一个基础镜像"
LABEL org.opencontainers.image.title="EMO-CAT基础镜像"
LABEL org.opencontainers.image.description="用于EMO-CAT项目的Debian基础镜像"
LABEL org.opencontainers.image.vendor="EMO-CAT"
LABEL org.opencontainers.image.licenses="GPL-3.0"
USER root
# Minimal runtime deps: certificates + tzdata + coreutils (for chroot --userspec)
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    coreutils; \
    rm -rf /var/lib/apt/lists/*

# Create a conventional runtime user/group (final switch happens in entrypoint via chroot --userspec)
RUN groupadd --gid 10001 emo && \
    useradd --uid 10001 --gid 10001 --create-home --home-dir /emo --shell /sbin/nologin emo
WORKDIR /emo
# Prepare data/log directories with sane defaults
RUN set -eux; \
    mkdir -p /data /logs; \
    chown -R emo:emo /data /logs /emo; \
    chmod 0750 /data /logs
LABEL com.centurylinklabs.watchtower.enable="true"
ENV TZ=Asia/Shanghai

# Copy the freshly built binary and the entrypoint
COPY --from=builder /usr/local/bin/template-worker /usr/bin/template-worker
USER emo
ENTRYPOINT [ "template-worker" ]
#docker build -t "emo-worker:dev" . -f Dockerfile