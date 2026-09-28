#!/usr/bin/env bash
# Build PhotonVision's linuxarm64 fat jar from the PhotonVision checkout in the
# current directory. The helios-raze photonvision-jar artifact runs this in
# the build container.
#
# Environment (all optional):
#   PHOTONVISION_VERSION       forced -PversionString (jar name and UI version)
#   LIBCAMERA_DRIVER_VERSION   -PlibcameraDriverVersion to consume
#   MAVEN_LOCAL_REPO           maven local repo shared with the driver build
#   PHOTONVISION_PREBUILD      gradle tasks to run in a separate invocation
#                              before the jar (space separated)
set -euo pipefail

args=(--no-daemon -PArchOverride=linuxarm64)
if [ -n "${MAVEN_LOCAL_REPO:-}" ]; then
  mkdir -p "${MAVEN_LOCAL_REPO}"
  args+=("-Dmaven.repo.local=${MAVEN_LOCAL_REPO}")
fi
if [ -n "${PHOTONVISION_VERSION:-}" ]; then
  args+=("-PversionString=${PHOTONVISION_VERSION}")
fi
if [ -n "${LIBCAMERA_DRIVER_VERSION:-}" ]; then
  args+=("-PlibcameraDriverVersion=${LIBCAMERA_DRIVER_VERSION}")
fi

# The WPILib arm64 cross toolchain for photon-targeting's natives lives in the
# Gradle user home; this is a no-op once it is installed.
./gradlew "${args[@]}" installArm64Toolchain

if [ -n "${PHOTONVISION_PREBUILD:-}" ]; then
  # shellcheck disable=SC2086 # task list is intentionally word-split
  ./gradlew "${args[@]}" ${PHOTONVISION_PREBUILD}
fi

./gradlew "${args[@]}" :photon-targeting:jar :photon-server:shadowJar
