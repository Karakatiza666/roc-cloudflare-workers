#!/usr/bin/env bash
# Check one Roc nightly: glue, build, layout, export lists (7a), node test, overflow test.
# On a pass, record the nightly in compat/last-stack-first-nightly. Releases build with that nightly.
# The platform has no fallback for a data-first module (js/runner.js refuses it), so a nightly that is not
# stack-first cannot be used at all: bench/build.sh and this job fail.
# Usage: bench/ci-layout.sh <tag>   (e.g. nightly-2026-10-19-601b54c). Env: ZIG, optional ROC. Exit 1 on a failure.
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:?usage: bench/ci-layout.sh <tag>}
out=.cache/ci/$tag
ROC=${ROC:-$(bench/get-roc.sh "$tag")}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig
# The glue must equal the committed file. Check it before bench/build.sh copies the new glue over it.
ROC=$ROC bench/glue.sh "$out/glue"
diff -u host/roc_platform_abi.zig "$out/glue/roc_platform_abi.zig" ||
  { echo "FAIL $tag: host/roc_platform_abi.zig is not the glue of this nightly. Run bench/build.sh and commit it." >&2; exit 1; }
ROC=$ROC OUT=$out bench/build.sh ||
  { echo "FAIL $tag: the build failed. If check-layout.mjs says DATA-FIRST: the platform has no fallback, so this nightly cannot be used at all." >&2; exit 1; }
node bench/check-layout.mjs --header platform/main.roc "$out"/app.wasm "$out"/app_pad.wasm "$out"/app_deep.wasm "$out"/app_prod.wasm
node bench/exports-test.mjs "$out"/app_prod.wasm "$out"/app.wasm
node bench/node-test.mjs "$out"/app.wasm
node bench/overflow-test.mjs "$out"/app_deep.wasm
echo "$tag" > compat/last-stack-first-nightly
echo "PASS $tag"
