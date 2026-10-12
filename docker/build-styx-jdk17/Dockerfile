# The build container for PhotonVision 2026 on the Styx backend: the build
# image plus Temurin 17 and pnpm 10 (as docker/build-jdk17, for 2026's Gradle
# 8.14.3) and Rust plus zig (as docker/build-styx, for photon-styx). Only the
# styx photonvision-jar artifact of a pv2026 build uses it.
#
#   docker build -t photonvision-gaia-build-styx-jdk17:trixie docker/build-styx-jdk17
FROM photonvision-gaia-build:trixie

ARG TEMURIN_17_VERSION=17.0.16+8
RUN set -eux; \
    v="${TEMURIN_17_VERSION}"; \
    curl -sSfL "https://api.adoptium.net/v3/binary/version/jdk-${v}/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" -o /tmp/jdk17.tar.gz; \
    mkdir -p /opt/temurin-17; \
    tar -xzf /tmp/jdk17.tar.gz -C /opt/temurin-17 --strip-components=1; \
    rm /tmp/jdk17.tar.gz; \
    /opt/temurin-17/bin/java -version

ENV JAVA_HOME=/opt/temurin-17

# PhotonVision 2026's Gradle build runs the pnpm on PATH (its node plugin does
# not download one): pnpm 10, as upstream's 2026 CI. pnpm 11+ fails the client
# install on the dependencies' ignored build scripts (ERR_PNPM_IGNORED_BUILDS).
RUN npm install -g pnpm@10.34.6 \
    && npm cache clean --force \
    && pnpm --version

ARG ZIG_VERSION=0.15.2
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:${PATH}
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.99.0 --no-modify-path \
    && rustup target add aarch64-unknown-linux-gnu \
    && chmod -R a+rwX /opt/rustup /opt/cargo
RUN curl -sSfL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig
