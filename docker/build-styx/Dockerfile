# The build container for the Styx vision backend: the normal build image plus a Rust toolchain
# (1.99, aarch64 target) and zig, which build photon-styx (libphotonstyx.so) for the Raze's
# glibc 2.41 (photon-styx/tools/zig-cc-aarch64.sh). Only the styx photonvision-jar artifact uses it.
#
#   docker build -t photonvision-gaia-build-styx:trixie docker/build-styx
FROM photonvision-gaia-build:trixie

ARG ZIG_VERSION=0.15.2
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.99.0 \
    && /root/.cargo/bin/rustup target add aarch64-unknown-linux-gnu
RUN curl -sSfL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig
ENV PATH=/root/.cargo/bin:${PATH}
