#!/usr/bin/env bash
# Build PhotonVision's linuxarm64 fat jar from the PhotonVision checkout in the
# current directory. The raze photonvision-jar artifact runs this in
# the build container.
#
# Environment (all optional):
#   PHOTONVISION_VERSION       forced -PversionString (jar name and UI version)
#   LIBCAMERA_DRIVER_VERSION   -PlibcameraDriverVersion to consume
#   MAVEN_LOCAL_REPO           maven local repo shared with the driver build
#   PHOTONVISION_PREBUILD      gradle tasks to run in a separate invocation
#                              before the jar (space separated)
#
# Also builds the offline docs (Sphinx, docs/) so the jar serves /docs/; needs
# python3-venv and network access for pip on the first run.
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

# Offline docs: photon-server copies docs/build/html into the jar's web root
# (served at /docs/) only if it exists, and a clean checkout has none, so build
# it here. The Sphinx venv is cached in HOME per requirements file. Warnings
# don't fail the build (upstream's -W is for the docs site, not for bundling).
if [ -f docs/requirements.txt ]; then
  req_hash=$(sha256sum docs/requirements.txt | cut -c1-16)
  venv="${HOME:-/tmp}/.cache/photonvision-docs-venv-${req_hash}"
  if [ ! -x "${venv}/bin/sphinx-build" ]; then
    python3 -m venv "${venv}"
    "${venv}/bin/pip" install --quiet --disable-pip-version-check -r docs/requirements.txt
  fi
  # Rebuild only when the docs sources (or the Sphinx requirements) change:
  # regenerating them rewrites docs/build/html, a Gradle input of
  # photon-server, which would otherwise re-run classes and shadowJar on every
  # build.
  docs_hash=$(
    {
      echo "${req_hash}"
      find docs -path docs/build -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
    } | sha256sum | cut -c1-32
  )
  stamp=docs/build/.html-source-hash
  if [ ! -f docs/build/html/index.html ] || [ "$(cat "${stamp}" 2>/dev/null)" != "${docs_hash}" ]; then
    rm -rf docs/build/html
    make -C docs html SPHINXBUILD="${venv}/bin/sphinx-build" SPHINXOPTS="--keep-going -q"
    if [ ! -f docs/build/html/index.html ]; then
      echo "build-photonvision-jar: docs/build/html/index.html was not produced" >&2
      exit 1
    fi
    printf '%s\n' "${docs_hash}" > "${stamp}"
  fi
fi

./gradlew "${args[@]}" :photon-targeting:jar :photon-server:shadowJar

# The jar must carry the docs, or PhotonVision answers /docs/index.html with 404.
# (List first: `unzip -l | grep -q` fails under pipefail when grep exits early.)
jar=$(ls photon-server/build/libs/photonvision-*-linuxarm64.jar 2>/dev/null | head -1)
if [ -f docs/requirements.txt ] && [ -n "${jar}" ]; then
  listing=$(unzip -l "${jar}")
  case "${listing}" in
    *"web/docs/index.html"*) ;;
    *)
      echo "build-photonvision-jar: ${jar} has no web/docs/index.html" >&2
      exit 1
      ;;
  esac
fi
