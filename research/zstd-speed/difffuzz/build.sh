#!/usr/bin/env bash
# Build the differential fuzz (native, ReleaseSafe) into out/difffuzz.
set -euo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/env.sh"; L=$D/.cache/src/zstd/lib
mkdir -p "$D/out"
"$ZIG" build-exe -O ReleaseSafe -lc --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
  -cflags -O2 -DZSTD_DISABLE_ASM -DZSTD_LEGACY_SUPPORT=0 -DZSTD_NO_TRACE -I$L -I$L/common -- \
  $L/common/{entropy_common,error_private,fse_decompress,xxhash,zstd_common}.c $L/decompress/{huf_decompress,zstd_ddict,zstd_decompress,zstd_decompress_block}.c \
  --dep zz -Mroot="$D/difffuzz/difffuzz.zig" -Mzz="$D/.cache/src/zaxified_zig-libs/modules/zstd/src/root.zig" \
  -femit-bin="$D/out/difffuzz"
