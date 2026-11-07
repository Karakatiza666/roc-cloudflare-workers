#!/usr/bin/env bash
# Make a platform copy whose release host has another allocator: <dir>/main.roc and <dir>/targets/wasm32/host.wasm.
# The allocator file must have the shape of hostlib/alloc.zig (the same exports); research/alloc/versions/v9*.zig are.
# Usage: ZIG=<zig 0.17> research/alloc/variant-platform.sh <alloc.zig> <dir> [-Dtrace=true]
# Env (research/alloc/foreign): EXTRA_ZIG (more files for hostlib/), EXTRA_OBJ (a wasm object that wasm-ld -r merges
# into the host object), SUM_OFF=1 (the release host takes sum mode 0, as the bench host; never for production).
# The work copy is .cache/hostvar/ (build.zig, host/, hostlib/, platform/); hostlib/ and platform/ of the repo are not changed.
set -euo pipefail
: "${ZIG:?set ZIG to the Zig 0.17 binary}"
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
mkdir -p "$2"
D=$(cd "$2" && pwd)
W=$R/.cache/hostvar
rm -rf "$W"
mkdir -p "$W"
cp "$R/build.zig" "$W/"
rsync -a "$R/host" "$R/hostlib" "$R/platform" "$W/"
cp "$SRC" "$W/hostlib/alloc.zig"
for f in ${EXTRA_ZIG:-}; do cp "$f" "$W/hostlib/"; done
if [ "${SUM_OFF:-}" = 1 ]; then
  grep -q 'if (!BENCH and m == 0) return 0;' "$W/host/host.zig"
  sed -i 's/if (!BENCH and m == 0) return 0;/_ = BENCH; \/\/ SUM_OFF: research build/' "$W/host/host.zig"
fi
cd "$W"
export ZIG_GLOBAL_CACHE_DIR=$R/.cache/zig ZIG_LOCAL_CACHE_DIR=$W/.zig-cache
if [ "${3:-}" = -Dtrace=true ]; then
  "$ZIG" build -Dtrace=true --prefix "$W/out"
  cp "$W/out/host-trace.wasm" "$W/platform/targets/wasm32/host.wasm"
else
  "$ZIG" build
  if [ -n "${EXTRA_OBJ:-}" ]; then
    "$ZIG" wasm-ld -r "$W/platform/targets/wasm32/host.wasm" "$EXTRA_OBJ" -o "$W/host-merged.wasm"
    cp "$W/host-merged.wasm" "$W/platform/targets/wasm32/host.wasm"
  fi
fi
rsync -a --delete "$W/platform/" "$D/"
echo "variant platform: $D/main.roc ($(basename "$1"))"
