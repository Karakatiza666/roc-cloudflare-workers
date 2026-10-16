#!/usr/bin/env bash
# Build the research apps for allocator versions: out/app_<v>.wasm (bench/app.roc)
# and out/app_v_<v>.wasm (the string-loop app). Usage: research/alloc/build.sh [v0 v1 v2 v3 v5 ... port]
# Each build: a copy of the repo in .work/, the harness files over it, versions/<v>.zig as hostlib/alloc.zig.
# Env: ZIG (Zig 0.17, default: zig on PATH), ROC (default: bench/get-roc.sh).
# TRACE=1: build only out/app_<v>_trace.wasm, which calls js_trace at each allocator call (scripts/trace.mjs).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../.." && pwd)
ZIG=${ZIG:-zig}
W=$D/.work
mkdir -p "$W" "$D/out"
rsync -a --delete --exclude .git --exclude research --exclude .zig-cache --exclude bench/out "$R/" "$W/"
cp -r "$D/harness/." "$W/"
cd "$W"
export ROC_CACHE_DIR=$W/.cache/roc XDG_CACHE_HOME=$W/.cache ZIG_GLOBAL_CACHE_DIR=$W/.cache/zig
ROC=${ROC:-$(bench/get-roc.sh)}
"$ROC" glue host/ZigGlue.roc .cache/glue platform/main.roc >/dev/null
cp .cache/glue/roc_platform_abi.zig host/roc_platform_abi.zig
for v in "${@:-v0 v1 v2 v3 v5}"; do
  for vv in $v; do
    # "port": the production allocator (hostlib/alloc.zig, PLAN.md 6e).
    if [ "$vv" = port ]; then src=$R/hostlib/alloc.zig; else src=$D/versions/$vv.zig; fi
    python3 "$D/probe.py" "$src" hostlib/alloc.zig
    "$ZIG" build -Dch_shift=12
    if [ "${TRACE:-0}" = 1 ]; then apps=app; sfx=_trace; else apps="app app_v"; sfx=; fi
    for app in $apps; do
      "$ROC" build --opt=speed --target=wasm32 --wasm-memory=0 --wasm-stack-size=1048576 --no-cache \
        --output="$D/out/${app}_$vv$sfx.wasm" bench/$app.roc >/dev/null || [ $? -eq 2 ]  # 2: warnings only (the dbg in bench/app.roc)
    done
    echo "built $vv"
  done
done
