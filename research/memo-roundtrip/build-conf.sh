#!/usr/bin/env bash
# Build only the bench host and conformance.wasm (a part of bench/build.sh). Env: ZIG, ROC. Optional: OPT (speed), OUT_WASM, SKIP_HOST=1.
set -euo pipefail
cd "$(dirname "$0")/../.."
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig
if [ ! -f .cache/glue/roc_platform_abi.zig ]; then ROC=$ROC bench/glue.sh .cache/glue; fi
cp .cache/glue/roc_platform_abi.zig host/roc_platform_abi.zig
[ "${SKIP_HOST:-}" = 1 ] || "$ZIG" build -Dbench=true ${ZIG_FLAGS:-}
mkdir -p bench/out
"$ROC" build --opt=${OPT:-speed} --target=wasm32 --no-cache --output=${OUT_WASM:-bench/out/conformance.wasm} conformance/app.roc || [ $? -eq 2 ]
