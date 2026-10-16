#!/usr/bin/env bash
# Check one Roc nightly: glue, build, layout, node test, overflow test.
# On a pass, record the nightly in compat/last-stack-first-nightly. Releases build with that nightly.
# Usage: bench/ci-layout.sh <tag>   (e.g. nightly-2026-10-12-2664a27). Env: ZIG, optional ROC. Exit 1 on a failure.
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:?usage: bench/ci-layout.sh <tag>}
out=.cache/ci/$tag
ROC=${ROC:-$(bench/get-roc.sh "$tag")}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig
# The glue must equal the committed file. Check it before bench/build.sh copies the new glue over it.
rm -rf "$out/glue"
"$ROC" glue host/ZigGlue.roc "$out/glue" platform/main.roc >/dev/null
diff -u host/roc_platform_abi.zig "$out/glue/roc_platform_abi.zig" ||
  { echo "FAIL $tag: host/roc_platform_abi.zig is not the glue of this nightly. Run bench/build.sh and commit it." >&2; exit 1; }
ROC=$ROC OUT=$out bench/build.sh
node bench/check-layout.mjs --header platform/main.roc "$out"/app.wasm "$out"/app_pad.wasm "$out"/app_deep.wasm
node bench/node-test.mjs "$out"/app.wasm
node bench/overflow-test.mjs "$out"/app_deep.wasm --expect-shared
echo "$tag" > compat/last-stack-first-nightly
echo "PASS $tag"
