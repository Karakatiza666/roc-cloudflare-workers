#!/usr/bin/env bash
# Build the allocator test driver (bench/out/alloc_driver.wasm) from hostlib/, and run the
# allocator tests of PLAN.md 6d and 6e on it. A second driver (alloc_driver_grow.wasm) asks JS before
# each grow (`js_grow`, 4b): bench/grow.mjs, bench/counters.mjs. Env: ZIG (Zig 0.17). Exit 1 when a test fails.
set -euo pipefail
cd "$(dirname "$0")/.."
W=.cache/alloc-driver
mkdir -p "$W" bench/out
export ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig ZIG_LOCAL_CACHE_DIR=$PWD/$W/.zig-cache
printf 'pub const small_buffers = false;\npub const bench = true;\npub const track_live = true;\npub const ask_js = false;\n' > "$W/build_options.zig"
"$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseSmall -fno-entry -rdynamic --stack 1048576 \
  --dep hostlib -Mroot=bench/alloc_driver.zig --dep build_options -Mhostlib=hostlib/root.zig -Mbuild_options="$W/build_options.zig" \
  -femit-bin=bench/out/alloc_driver.wasm
printf 'pub const small_buffers = false;\npub const bench = true;\npub const track_live = true;\npub const ask_js = true;\n' > "$W/build_options_grow.zig"
"$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseSmall -fno-entry -rdynamic --stack 1048576 \
  --dep hostlib -Mroot=bench/alloc_driver.zig --dep build_options -Mhostlib=hostlib/root.zig -Mbuild_options="$W/build_options_grow.zig" \
  -femit-bin=bench/out/alloc_driver_grow.wasm
rc=0
node bench/grow.mjs bench/out/alloc_driver_grow.wasm || rc=1
for t in dfree fmark reserve adopt sumjs oomclean rowner; do node "bench/$t.mjs" bench/out/alloc_driver.wasm || rc=1; done
# PLAN.md 4h, 4j: the counters and the idle reset against a manual walk of the unit tables (both drivers).
node bench/counters.mjs bench/out/alloc_driver.wasm bench/out/alloc_driver_grow.wasm || rc=1
exit $rc
