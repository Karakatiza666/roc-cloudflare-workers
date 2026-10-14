#!/usr/bin/env bash
# Build the replay module for allocator versions: out/replay_<v>.wasm. Usage: replay/build.sh [v0 v1 ...]
# Env: ZIG (default: roc-shpadoinkle tools/zig), OPT (default: ReleaseSmall, as the host build),
# ZFLAGS (more zig flags, e.g. -fno-strip for function names in a profile).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
A=$(cd "$D/.." && pwd)
ZIG=${ZIG:-$A/../../../../roc-shpadoinkle/tools/zig/zig}
W=$A/.work-replay
mkdir -p "$W" "$A/out"
export ZIG_GLOBAL_CACHE_DIR=$W/.cache/zig ZIG_LOCAL_CACHE_DIR=$W/.zig-cache
for v in "${@:-v0 v1 v2 v3 v5}"; do
  cp "$D/replay.zig" "$D/mem.zig" "$D/canary.zig" "$D/build_options.zig" "$W/"
  cp "$A/versions/$v.zig" "$W/alloc.zig"
  (cd "$W" && "$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O "${OPT:-ReleaseSmall}" \
    ${ZFLAGS:-} -fno-entry -rdynamic --stack 1048576 --dep build_options -Mroot=replay.zig -Mbuild_options=build_options.zig \
    -femit-bin="$A/out/replay_$v.wasm")
  echo "built replay_$v"
done
