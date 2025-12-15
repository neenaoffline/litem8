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

# Build optimized release binary
RUN zig build -Doptimize=ReleaseSafe

# Copy libsqlite.so to a known location
RUN mkdir -p /build/zig-out/lib && \
    find .zig-cache -name "libsqlite.so" -type f -print -quit | xargs -I {} cp {} /build/zig-out/lib/

# Stage 2: Debian slim runtime
FROM debian:bookworm-slim

# Copy the binary and shared library from builder
COPY --from=builder /build/zig-out/bin/litem8 /usr/local/bin/litem8
COPY --from=builder /build/zig-out/lib/libsqlite.so /usr/local/lib/

# Update library cache
RUN ldconfig

ENTRYPOINT ["litem8"]
