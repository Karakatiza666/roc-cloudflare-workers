#!/usr/bin/env bash
# Build the wasm32 harness into research/native/out/: native-small.wasm (ReleaseSmall, as the production host) and
# native-fast.wasm (ReleaseFast). Uses the real hostlib/alloc.zig, and does not touch the repo build.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../../.." && pwd)
source "$D/../env.sh"
mkdir -p "$D/../out"
cd "$R"
for mode in Small Fast; do
  "$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O Release$mode -fno-entry -rdynamic \
    --stack 1048576 --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --dep alloc --dep native -Mroot=research/native/harness/harness.zig \
    --dep build_options -Malloc=hostlib/alloc.zig \
    -Mnative=hostlib/native/native.zig \
    -Mbuild_options=research/native/harness/build_options.zig \
    -femit-bin="research/native/out/native-$(echo $mode | tr A-Z a-z).wasm"
done
ls -l research/native/out/*.wasm
