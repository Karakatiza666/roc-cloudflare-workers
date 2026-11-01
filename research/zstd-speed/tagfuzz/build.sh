#!/usr/bin/env bash
# Build the corrupt-input check (native, ReleaseSafe) into out/tagfuzz.
set -euo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/env.sh"; R=$(cd "$D/../.." && pwd)
mkdir -p "$D/out"
"$ZIG" build-exe -O ReleaseSafe --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
  --dep new --dep old -Mroot="$D/tagfuzz/tagfuzz.zig" \
  --dep zstd_dec -Mnew="$R/hostlib/native/zstd.zig" -Mold="$D/variants/std/zstd.zig" -Mzstd_dec="$R/hostlib/zstd/decompress.zig" \
  -femit-bin="$D/out/tagfuzz"
