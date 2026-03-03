#!/bin/sh
set -eu

JAVA_OPTS="${PHOTONVISION_JAVA_OPTS:--Xmx512m}"
EXTRA_ARGS="${PHOTONVISION_ARGS:-}"
JAVA_BIN="${PHOTONVISION_JAVA_BIN:-/usr/bin/java}"

if [ ! -x "${JAVA_BIN}" ] && [ -x /usr/lib/jvm/bin/java ]; then
  JAVA_BIN="/usr/lib/jvm/bin/java"
fi

if [ ! -x "${JAVA_BIN}" ]; then
  echo "PhotonVision Java runtime not found (checked ${JAVA_BIN} and /usr/lib/jvm/bin/java)." >&2
  exit 127
fi

# shellcheck disable=SC2086
exec "${JAVA_BIN}" ${JAVA_OPTS} -jar /opt/photonvision/photonvision.jar ${EXTRA_ARGS}
