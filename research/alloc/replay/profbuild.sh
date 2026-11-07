#!/usr/bin/env bash
# Build a replay module for a profile (scripts/prof.mjs): names kept, and the main allocator
# functions not inlined, so the profile shows each one. Usage: replay/profbuild.sh v7 [v8 ...]
# Output: out/replay_<v>_prof.wasm. Env: ZIG, OPT (default ReleaseSmall).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
A=$(cd "$D/.." && pwd)
ZIG=${ZIG:-zig}
W=$A/.work-prof
mkdir -p "$W/native" "$A/out"
export ZIG_GLOBAL_CACHE_DIR=$W/.cache/zig ZIG_LOCAL_CACHE_DIR=$W/.zig-cache
FNS='smallAlloc|smallFree|largeAlloc|largeFree|takeRun|takeLow|runGive|runTake|runFind|runInsert|runRemove|poolGrow|taskOf|taskFind|taskEnd|largeGrowInPlace|setRange|smallStart|usableAt|blockUnit|availPush|availRemove|sumTask|fletcher|smallGive|listPush|listRemove|release|allocIn|hostRealloc|hostDealloc|hostAlloc|onFreeList|cacheTake|pageSetup|smallFast'
for v in "$@"; do
  cp "$D/replay.zig" "$D/canary.zig" "$D/cpu.zig" "$D/build_options.zig" "$W/"
  cp "$D/native/native.zig" "$W/native/"
  # copyBytes: its own function, so the copy shows.
  sed -E 's/^pub inline fn copyBytes/pub noinline fn copyBytes/' "$D/mem.zig" > "$W/mem.zig"
  sed -E "s/^(pub )?(inline )?fn ($FNS)\(/\1noinline fn \3(/" "$A/versions/$v.zig" > "$W/alloc.zig"
  (cd "$W" && "$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O "${OPT:-ReleaseSmall}" \
    -fno-strip -fno-entry -rdynamic --stack 1048576 --dep build_options -Mroot=replay.zig -Mbuild_options=build_options.zig \
    -femit-bin="$A/out/replay_${v}_prof.wasm")
  echo "built replay_${v}_prof"
done
