# CeraLive Image Builder Docker Environment
# Multi-stage build for efficient caching and minimal final image

FROM debian:bookworm-slim AS base

# Build arguments
ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_DATE
ARG BUILD_VERSION

# Labels for identification
LABEL maintainer="CERALIVE <dev@ceralive.com>"
LABEL description="CeraLive Image Building Environment"
LABEL version="${BUILD_VERSION}"
LABEL build-date="${BUILD_DATE}"

# Essential build tools and cross-compilation support
RUN apt-get update && apt-get install -y \
    # Build essentials
    build-essential \
    cmake \
    pkg-config \
    git \
    curl \
    wget \
    \
    # Cross-compilation tools
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    libc6-dev-arm64-cross \
    \
    # Image building tools
    debootstrap \
    qemu-user-static \
    binfmt-support \
    \
    # Partitioning and filesystem tools
    parted \
    kpartx \
    dosfstools \
    e2fsprogs \
    util-linux \
    \
    # Archive and compression
    zip \
    unzip \
    xz-utils \
    zstd \
    \
    # Device tree compiler
    device-tree-compiler \
    \
    # Python for build scripts
    python3 \
    python3-pip \
    python3-yaml \
    python3-jinja2 \
    \
    # Network tools for testing
    iproute2 \
    iputils-ping \
    netcat-openbsd \
    \
    # Clean up to reduce image size
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install additional Python packages for build automation
RUN pip3 install --no-cache-dir --break-system-packages \
    pyyaml \
    jinja2 \
    requests \
    click

# Setup cross-compilation environment
ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV CC=aarch64-linux-gnu-gcc
ENV CXX=aarch64-linux-gnu-g++
ENV AR=aarch64-linux-gnu-ar
ENV STRIP=aarch64-linux-gnu-strip

# Setup QEMU for emulation
RUN update-binfmts --enable qemu-aarch64

# Create workspace directories with root ownership (needed for image building)
RUN mkdir -p /workspace /output /cache /tmp/build

# Install U-Boot tools for bootloader building
FROM base AS uboot-tools

RUN apt-get update && apt-get install -y \
    u-boot-tools \
    bc \
    flex \
    bison \
    libssl-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Final stage with all tools
FROM uboot-tools AS final

# Copy build scripts and configurations
COPY scripts/*.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Setup environment variables for build
ENV WORKSPACE=/workspace
ENV OUTPUT_DIR=/output
ENV CACHE_DIR=/cache
# Auto-detect based on CPU cores
ENV BUILD_JOBS=0

# Copy entrypoint script (run as root for image building)
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set working directory and run as root (needed for image building)
WORKDIR /workspace

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]

# Health check to verify the build environment
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh || exit 1
