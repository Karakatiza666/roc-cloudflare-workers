#!/usr/bin/env bash
# Build the probe wasm of each variant: out/<variant>-<small|fast>.wasm.
# Usage: build.sh [variant...] (default: all in variants/). MODES="Small Fast" by default.
# A variant is a directory with a zstd.zig (the API of hostlib/native/zstd.zig). native.zig is the copy
# of hostlib. Optional: c.args (extra arguments for zig build-exe: C files and flags, one per line, paths
# relative to the variant directory or absolute), deps.names and deps.args (the modules that native.zig imports).
# MODO=ReleaseFast: build the modules of deps.args and zstd_dec (hostlib/zstd, the decoder of hostlib) with that mode
# (the rest with the mode of MODES). hostlib/alloc.zig imports hostlib/native, so every variant has the module zstd_dec.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../.." && pwd)
source "$D/env.sh"
MODES=${MODES:-"Small Fast"}
cd "$R"
vs=("$@"); [ ${#vs[@]} -gt 0 ] || vs=($(ls "$D/variants"))
for v in "${vs[@]}"; do
  S="$D/out/src/$v"; rm -rf "$S"; mkdir -p "$S"
  cp hostlib/native/native.zig "$S/native.zig"
  cp -r "$D/variants/$v/." "$S/"
  [ "$v" = new ] && cp hostlib/native/zstd.zig "$S/zstd.zig"
  extra=(); [ -f "$S/c.args" ] && while read -r l; do [ -n "$l" ] && extra+=($(eval echo "$l")); done < "$S/c.args"
  mods=(); [ -f "$S/deps.args" ] && while read -r l; do [ -n "$l" ] && mods+=($(eval echo "$l")); done < "$S/deps.args"
  for mode in $MODES; do
    o="$D/out/$v-$(echo $mode | tr A-Z a-z)${MODO:+-mod$(echo $MODO | tr A-Z a-z)}.wasm"
    "$ZIG" build-exe -target wasm32-freestanding -mcpu=generic+simd128 -O Release$mode -fno-entry -rdynamic \
      --stack 1048576 --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
      "${extra[@]}" \
      --dep alloc --dep native -Mroot=research/native/harness/harness.zig \
      --dep build_options --dep zstd_dec -Malloc=hostlib/alloc.zig \
      $( [ -f "$S/deps.names" ] && printf -- '--dep %s ' $(cat "$S/deps.names") ) -Mnative="$S/native.zig" \
      ${MODO:+-O $MODO} "${mods[@]}" \
      -Mbuild_options=research/native/harness/build_options.zig \
      -O ${MODO:-ReleaseSafe} -Mzstd_dec=hostlib/zstd/decompress.zig \
      -femit-bin="$o"
    printf '%-28s %8d B\n' "$(basename "$o")" "$(stat -c %s "$o")"
  done
done
