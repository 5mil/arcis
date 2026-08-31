# Arcis — multi-stage production image
# Build: docker build -t arcis .
# Run:   docker run -p 8080:8080 -v $(pwd)/models:/models arcis --model /models/model.gguf

# ---------------------------------------------------------------------------
# Stage 1: build
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.14 (adjust if you pin a different version)
ARG ZIG_VERSION=0.14.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s /opt/zig-linux-x86_64-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /src
COPY . .

RUN zig build -Doptimize=ReleaseFast

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 arcis

WORKDIR /app

COPY --from=builder /src/zig-out/bin/arcis /app/arcis

# Persistent dirs (mount volumes in production)
RUN mkdir -p /app/arcis-projects /models \
    && chown -R arcis:arcis /app /models

USER arcis

ENV PORT=8080
EXPOSE 8080

# Default: no model. Override with --model /models/your.gguf
ENTRYPOINT ["/app/arcis"]
CMD ["--tier", "visio", "--port", "8080"]
