# Stage 1: Build with Debian + Zig
FROM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    xz-utils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download and install Zig
ARG ZIG_VERSION=0.15.2
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) ZIG_ARCH="x86_64" ;; \
        arm64) ZIG_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz && \
    tar -xJf /tmp/zig.tar.xz && \
    mv zig-${ZIG_ARCH}-linux-${ZIG_VERSION} /opt/zig && \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /build
COPY . .

# Build optimized release binary (SQLite is bundled, no external deps)
RUN zig build -Doptimize=ReleaseSafe

# Stage 2: Minimal runtime (binary is self-contained)
FROM debian:bookworm-slim

# Copy the self-contained binary from builder
COPY --from=builder /build/zig-out/bin/litem8 /usr/local/bin/litem8

ENTRYPOINT ["litem8"]
