#!/usr/bin/env bash
# Repeatable PhotonVision benchmark for a Prometheus Dynamics Raze (CM5 + OV9782).
#
# Usage:
#   tools/bench/raze-bench.sh <label> [extra bench.mjs options]
#   e.g. tools/bench/raze-bench.sh baseline-2027-libcamera
#        tools/bench/raze-bench.sh pv-2026.3.4-release
#        tools/bench/raze-bench.sh styx-eidos --no-ws --proc=<backend process comm>
#
# Writes tools/bench/results/<label>.json (override with --out=PATH).
# Env: RAZE_HOST (default 172.31.12.81), RAZE_SSH (default root@$RAZE_HOST).
# Options (passed to bench.mjs): --window=30 --mjpeg-window=10 --settle=6 --phases=full,low,driver
#   --proc=java --stream-port=1182 --pv-port=5800 --no-ws
#
# What it does: reads image identity from :5899/.well-known/pd-device, then for each phase sets the
# PV AprilTag pipeline video mode (1280x800, then 640x400) or driver mode over the PV websocket,
# records PV-reported fps/latency/targets for --window s while sampling /proc + vcgencmd on the
# device over ssh (read-only, nothing written on the device), then measures delivered MJPEG fps on
# :1182 from the host. The original pipeline index / video mode / driver mode are restored after.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="${1:?usage: raze-bench.sh <label> [options]}"; shift
HOST="${RAZE_HOST:-172.31.12.81}"
SSH_TARGET="${RAZE_SSH:-root@$HOST}"

command -v node >/dev/null || { echo "node (>=22) required" >&2; exit 1; }
node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' || { echo "node >= 22 required" >&2; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" true || { echo "ssh $SSH_TARGET failed" >&2; exit 1; }

OUT="$HERE/results/$LABEL.json"
for a in "$@"; do case "$a" in --out=*) OUT="${a#--out=}";; esac; done

exec node "$HERE/bench.mjs" --host="$HOST" --ssh="$SSH_TARGET" --label="$LABEL" --out="$OUT" "$@"
