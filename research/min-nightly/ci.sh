#!/usr/bin/env bash
# CI check of the claim `min_nightly` in js/cfw.json: the apps build with that nightly against the hosts
# of the pinned nightly (the committed glue), and the tests that take a wasm file pass. Usage: research/min-nightly/ci.sh
# Env: ZIG (Zig 0.17), WORKERD (for the conformance run), GH_TOKEN (bench/get-roc.sh uses gh).
# try.sh prints the result of each step; this script fails when a step is not the expected one.
set -uo pipefail
cd "$(dirname "$0")/../.."
tag=$(node -p 'require("./js/cfw.json").min_nightly')
echo "min_nightly: $tag"
export ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig
"$ZIG" build -Dbench=true || exit 1
"$ZIG" build || exit 1
log=$(research/min-nightly/try.sh "$tag") || exit 1
echo "$log"
bad=0
# build: exit 0, or 2 for warnings only (bench/app.roc has a dbg on purpose)
grep -q '^build conformance: exit 0 ' <<<"$log" || bad=1
grep -q '^build app_prod: exit [02] ' <<<"$log" || bad=1
grep -q '^build app: exit [02] ' <<<"$log" || bad=1
grep -q '^build app_b3: exit [02] ' <<<"$log" || bad=1
grep -q '^build app_trap: exit [02] ' <<<"$log" || bad=1
grep -q '^node-test: exit 0$' <<<"$log" || bad=1
grep -q '^handler-test: exit 0$' <<<"$log" || bad=1
grep -q '^conformance: exit 0 ' <<<"$log" || bad=1
# exports-test may fail only for the 3 exports of the compiler from nightly 2026-10-28
out=.cache/min-nightly/$tag
if ! grep ^FAIL "$out/exports-test.log" | grep -qv '__stack_\|^FAIL$'; then :; else echo "exports-test: a FAIL that is not a stack export"; bad=1; fi
[ "$bad" = 0 ] && echo "min_nightly OK" || { echo "min_nightly CHECK FAILED"; exit 1; }
