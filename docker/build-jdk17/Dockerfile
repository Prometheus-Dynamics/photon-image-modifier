# The build container for PhotonVision 2026 and its libcamera GL driver
# (build-raze-2026.toml): the normal build image plus a Temurin 17 JDK as
# JAVA_HOME. Both 2026 builds use Gradle 8.14.3, whose wrapper does not run on
# the base image's JDK 25 (Gradle supports Java 25 from 9.1), and PhotonVision
# 2026 compiles with a Java 17 toolchain. The image itself still runs the jar
# on its jlink'd Temurin 25 runtime. Only raze/photonvision-2026.toml's
# artifacts use this image.
#
#   docker build -t photonvision-gaia-build-jdk17:trixie docker/build-jdk17
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
