#!/usr/bin/env bash
# Make the files of one foreign backend: gen/fa_<b>.zig (fa.zig with BACKEND = .<b>) and, for a C backend,
# gen/<b>.o (wasm32 object; it imports `sbrk` from fa.zig). Usage: ZIG=<zig 0.17> foreign/gen.sh <b>...
# Backends: bump bumpr zig (std.heap.wasm_allocator) dl (dlmalloc) em (emmalloc) mi (mimalloc) tl (fa_tl.zig).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
: "${ZIG:?set ZIG to the Zig 0.17 binary}"
mkdir -p "$D/gen"
for b in "$@"; do
  sed "s/^const BACKEND: Backend = \.[a-z]*;/const BACKEND: Backend = .$b;/" "$D/fa.zig" > "$D/gen/fa_$b.zig"
  grep -q "BACKEND: Backend = .$b;" "$D/gen/fa_$b.zig"
  case $b in
    dl|em|mi)
      (cd "$D" && "$ZIG" cc -target wasm32-wasi -O2 -mbulk-memory -msimd128 -fPIC -Wno-date-time -Iem_inc \
        -Ivendor/mimalloc-2.2.4/include -c "$b.c" -o "gen/$b.o") ;;
  esac
  echo "gen $b"
done
