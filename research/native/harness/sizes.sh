#!/usr/bin/env bash
# Size of the Native code in wasm32 (bytes of the .wasm): the harness with and without it, and each part alone.
# The parts alone also hold the allocator code that they use, so they do not add up to the total.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../../.." && pwd)
source "$D/../env.sh"
cd "$R"
O=research/native/.cache/sizes
mkdir -p "$O"
build() { # name root.zig options.zig mode
  "$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O "Release$4" -fno-entry -rdynamic --stack 1048576 \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" --dep alloc --dep native --dep build_options -Mroot="$2" --dep build_options -Malloc=hostlib/alloc.zig \
    -Mnative=hostlib/native/native.zig -Mbuild_options="$3" -femit-bin="$O/$1.wasm" 2>/dev/null || true
}
for mode in Small Fast; do
  build "alloc-only-$mode" research/native/harness/harness_alloc_only.zig research/native/harness/build_options.zig $mode
  build "all-$mode" research/native/harness/harness.zig research/native/harness/build_options.zig $mode
  for part in 0 1 2; do
    printf 'pub const small_buffers = false;\npub const bench = false;\npub const track_live = true;\npub const owner_tag = true;\npub const ask_js = true;\npub const part = %s;\n' $part > "$O/opt$part.zig"
    build "part$part-$mode" research/native/harness/harness_parts.zig "$O/opt$part.zig" $mode
  done
done
echo "| Build | Small (B) | Fast (B) |"; echo "| --- | --- | --- |"
for n in alloc-only all part0 part1 part2; do
  l=$n; [ $n = part0 ] && l="zstd only"; [ $n = part1 ] && l="BLAKE3 only"; [ $n = part2 ] && l="SHA-256 only"
  echo "| $l | $(stat -c %s $O/$n-Small.wasm) | $(stat -c %s $O/$n-Fast.wasm) |"
done
