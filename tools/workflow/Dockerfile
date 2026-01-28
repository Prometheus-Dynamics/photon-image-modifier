FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    dosfstools \
    e2fsprogs \
    fuse3 \
    gdisk \
    git \
    graphviz \
    gnupg \
    jq \
    kpartx \
    libguestfs-tools \
    linux-image-generic \
    meson \
    ninja-build \
    openjdk-17-jdk \
    parted \
    patch \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    qemu-utils \
    qemu-user-static \
    util-linux \
    wget \
    xz-utils \
    libdrm-dev \
    libegl1-mesa-dev \
    libgbm-dev \
    libgl1-mesa-dev \
    qemu-system-arm \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install -g pnpm \
  && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/workflow-entrypoint
RUN chmod +x /usr/local/bin/workflow-entrypoint

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/workflow-entrypoint"]
