# Build environment for the whole Gaia build: source fetching, Buildroot, and
# the Java artifacts (the PhotonVision fat jar and the photon-libcamera-gl-driver
# JNI jar).
#
#   docker build -t photonvision-gaia-build:trixie docker/build
#
# Gaia runs every command in this image as the workspace owner, with HOME set
# to <workspace>/.gaia/docker-home, so Gradle, pnpm and toolchain caches persist
# in the workspace between builds.
# Debian trixie for OpenJDK 25 (PhotonVision 2027 and its WPILib build with a
# Java 25 toolchain) and Node 24 (photon-client's engines field).
FROM node:24-trixie-slim

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
        openjdk-25-jdk-headless \
        patch \
        perl \
        pkg-config \
        python3 \
        python3-venv \
        rsync \
        sed \
        tar \
        unzip \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# PhotonVision builds its web UI with pnpm through Gradle (which pins its own
# pnpm version); the global one is for running the client build by hand.
RUN npm install -g pnpm@11 \
    && npm cache clean --force

WORKDIR /workspace
