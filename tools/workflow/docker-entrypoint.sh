#!/bin/bash
set -euo pipefail

if [ ! -x /workspace/photon-image-modifier/tools/workflow/container-build.sh ]; then
  echo "Missing /workspace/photon-image-modifier/tools/workflow/container-build.sh" 1>&2
  exit 1
fi

exec /workspace/photon-image-modifier/tools/workflow/container-build.sh
