# The build container for the Styx vision backend: the normal build image plus a Rust toolchain
# (1.99, aarch64 target) and zig, which build photon-styx (libphotonstyx.so) for the Raze's
# glibc 2.41 (photon-styx/tools/zig-cc-aarch64.sh). Only the styx photonvision-jar artifact uses it.
#
# Gaia runs commands as the workspace owner, not root, so the toolchain lives in /opt and is
# world-readable. CARGO_HOME is writable for the registry cache.
#
#   docker build -t photonvision-gaia-build-styx:trixie docker/build-styx
FROM photonvision-gaia-build:trixie

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
