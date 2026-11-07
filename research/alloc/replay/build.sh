#!/usr/bin/env bash
# Build the replay module for allocator versions: out/replay_<v>.wasm. Usage: replay/build.sh [v0 v1 ... port]
# Env: ZIG (Zig 0.17, default: zig on PATH), OPT (default: ReleaseSmall, as the host build),
# ZFLAGS (more zig flags, e.g. -fno-strip for function names in a profile).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
A=$(cd "$D/.." && pwd)
ZIG=${ZIG:-zig}
W=$A/.work-replay
mkdir -p "$W" "$A/out"
export ZIG_GLOBAL_CACHE_DIR=$W/.cache/zig ZIG_LOCAL_CACHE_DIR=$W/.zig-cache
for v in "${@:-v0 v1 v2 v3 v5}"; do
  cp "$D/replay.zig" "$D/mem.zig" "$D/canary.zig" "$D/cpu.zig" "$D/build_options.zig" "$W/"
  mkdir -p "$W/native" && cp "$D/native/native.zig" "$W/native/"
  # "port": the production allocator (hostlib/alloc.zig, PLAN.md 6e).
  # "fa_<b>": a foreign backend (foreign/gen.sh first); a C backend also links foreign/gen/<b>.o.
  OBJ=
  if [ "$v" = port ]; then cp "$A/../../hostlib/alloc.zig" "$W/alloc.zig"
  elif [ "${v#fa_}" != "$v" ]; then
    cp "$A/foreign/gen/$v.zig" "$W/alloc.zig"; cp "$A/foreign/fa_tl.zig" "$W/" 2>/dev/null || true
    [ -f "$A/foreign/gen/${v#fa_}.o" ] && OBJ=$A/foreign/gen/${v#fa_}.o
  else cp "$A/versions/$v.zig" "$W/alloc.zig"; fi
  (cd "$W" && "$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O "${OPT:-ReleaseSmall}" \
    ${ZFLAGS:-} -fno-entry -rdynamic --stack 1048576 --dep build_options -Mroot=replay.zig $OBJ -Mbuild_options=build_options.zig \
    -femit-bin="$A/out/replay_$v.wasm")
  echo "built replay_$v"
done
