#!/usr/bin/env bash
# PLAN.md 8g: builds the measure app (`app.roc`, bench platform) with variants of the bench host.
#   ZIG=<zig 0.17> bench/8g/build.sh [variant ...]        variants: default (the bench host as bench/build.sh makes it),
#   tl_off (track_live=false), ot_off (track_live=false, owner_tag=false), fast (optimize mode fast), fast_tl_off
# Gives bench/8g/out/app-<variant>.wasm and out/host-<variant>.wasm. `default` is also out/app.wasm. The bench platform links
# the host from bench/platform/targets/wasm32/host.wasm (ignored by git): this script puts each variant there for its build and
# at the end the default host back, so the next `bench/build.sh` or test run sees the host of the tree.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig
variants=("$@")
[ ${#variants[@]} -gt 0 ] || variants=(default tl_off ot_off fast fast_tl_off)
mkdir -p bench/8g/out
flags() {
  case $1 in
    default) echo "" ;;
    tl_off) echo "-Dtrack_live=false" ;;
    ot_off) echo "-Dtrack_live=false -Downer_tag=false" ;;
    fast) echo "-Dopt=fast" ;;
    fast_tl_off) echo "-Dopt=fast -Dtrack_live=false" ;;
    *) echo "unknown variant $1" >&2; exit 1 ;;
  esac
}
for v in "${variants[@]}"; do
  (cd bench/8g/host-build && "$ZIG" build $(flags "$v") -Dout="../out/host-$v.wasm")
  cp "bench/8g/out/host-$v.wasm" bench/platform/targets/wasm32/host.wasm
  "$ROC" build --opt=speed --target=wasm32 --no-cache --output="bench/8g/out/app-$v.wasm" bench/8g/app.roc || [ $? -eq 2 ]
  echo "built $v: $(stat -c %s bench/8g/out/host-$v.wasm) bytes host, $(stat -c %s bench/8g/out/app-$v.wasm) bytes app"
done
cp bench/8g/out/app-default.wasm bench/8g/out/app.wasm 2>/dev/null || true
# The tree's own bench host again (`zig build -Dbench=true`, as bench/build.sh).
"$ZIG" build -Dbench=true
cmp bench/platform/targets/wasm32/host.wasm bench/8g/out/host-default.wasm && echo "host of the tree = host-default"
