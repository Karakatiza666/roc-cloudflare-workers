#!/usr/bin/env bash
# Start the registry Worker for regprof.mjs: regserve.mjs on 127.0.0.1:8787, inspector 9230, V8 jitdump in perf/.
# Usage: research/regprof/serve.sh   (runs in the foreground; stop with TERM). Needs state/ (README.md) and w2/.
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$P/perf"
cd "$P/perf"
rm -f "$P/state/worker.url"
export INSPECT_PORT=${INSPECT_PORT:-9230} MINIFLARE_WORKERD_V8_FLAGS=${MINIFLARE_WORKERD_V8_FLAGS---perf-prof}
export TALON_NOW=${TALON_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} W2_DIR=${W2_DIR:-$P/w2}
exec node "$P/regserve.mjs" "$P/state/worker" "$P/state" 8787
