# Build environment for the whole Gaia build: source fetching, Buildroot, and
# the Java artifacts (the PhotonVision fat jar and the photon-libcamera-gl-driver
# JNI jar).
#
#   docker build -t photonvision-gaia-build:bookworm docker/build
#
# Gaia runs every command in this image as the workspace owner, with HOME set
# to <workspace>/.gaia/docker-home, so Gradle, pnpm and toolchain caches persist
# in the workspace between builds.
FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bc \
        binutils \
        bison \
        build-essential \
        bzip2 \
        ca-certificates \
        cmake \
        cpio \
        curl \
        diffutils \
        file \
        findutils \
        flex \
        gawk \
        git \
        gzip \
        make \
        mtools \
        ninja-build \
        openjdk-17-jdk-headless \
        patch \
        perl \
        pkg-config \
        python3 \
        rsync \
        sed \
        tar \
        unzip \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# PhotonVision builds its web UI with pnpm through Gradle.
RUN npm install -g pnpm@10 \
    && npm cache clean --force

WORKDIR /workspace
