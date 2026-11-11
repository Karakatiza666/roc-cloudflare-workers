#!/usr/bin/env bash
# PLAN.md 11c: one edge run on fresh resources. It empties the R2 buckets (edge/wipe-r2.mjs), deletes the Workers and the
# resources (edge/deploy.sh delete), deploys again (edge/deploy.sh), and runs the checks (edge/run-edge.mjs). The checks
# expect fresh bindings (a D1 with no tables, empty buckets, new Durable Objects), as in Miniflare.
#   [SRC=<checkout>] edge/fresh-run.sh <result file>
# SRC: the checkout of the platform and of conformance/ (default this one), for example a worktree of the tag 0.0.9
# with its .cache/edge/app.wasm (edge/build.sh there).
set -euo pipefail
cd "$(dirname "$0")/.."
export EDGE=https://rocplat-test-app.bellup.workers.dev SERVER=https://rocplat-test-echo.bellup.workers.dev
export SRC=${SRC:-$PWD}
if curl -sf "$EDGE/__edge" >/dev/null; then node edge/wipe-r2.mjs || true; fi
edge/deploy.sh delete
edge/deploy.sh
sleep 20
CONF=$SRC/conformance node edge/run-edge.mjs > "$1"
tail -1 "$1"
