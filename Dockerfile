# Stage 1: Builder with Nix
FROM nixos/nix:latest AS builder

ARG TARGETARCH

# Enable flakes
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /build

# Copy source files
COPY . .

# Build static musl binary with Nix (select arch based on TARGETARCH)
RUN mkdir -p /tmp/out \
    && if [ "$TARGETARCH" = "arm64" ]; then \
         nix build .#litem8-static-aarch64 --no-link --print-out-paths > /tmp/store-path; \
       else \
         nix build .#litem8-static-x86_64 --no-link --print-out-paths > /tmp/store-path; \
       fi \
    && cp -rL $(cat /tmp/store-path)/bin/litem8 /tmp/out/

# Stage 2: Minimal scratch image
FROM scratch

# Copy the statically-linked binary from builder
COPY --from=builder /tmp/out/litem8 /litem8

ENTRYPOINT ["/litem8"]
