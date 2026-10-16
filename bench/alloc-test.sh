#!/usr/bin/env bash
# Build the allocator test driver (bench/out/alloc_driver.wasm) from hostlib/, and run the
# allocator tests of PLAN.md 6d and 6e on it. Env: ZIG (Zig 0.17). Exit 1 when a test fails.
set -euo pipefail
cd "$(dirname "$0")/.."
W=.cache/alloc-driver
mkdir -p "$W" bench/out
export ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig ZIG_LOCAL_CACHE_DIR=$PWD/$W/.zig-cache
printf 'pub const small_buffers = false;\npub const track_live = true;\npub const owner_tag = true;\n' > "$W/build_options.zig"
"$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseSmall -fno-entry -rdynamic --stack 1048576 \
  --dep hostlib -Mroot=bench/alloc_driver.zig --dep build_options -Mhostlib=hostlib/root.zig -Mbuild_options="$W/build_options.zig" \
  -femit-bin=bench/out/alloc_driver.wasm
rc=0
for t in dfree fmark reserve adopt sumjs oomclean rowner; do node "bench/$t.mjs" bench/out/alloc_driver.wasm || rc=1; done
exit $rc
