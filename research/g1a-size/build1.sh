#!/bin/sh
# Usage: research/g1a-size/build1.sh <app.roc> <out.wasm> [extra roc build flags]
# Build one app with --opt=size. Run from the submodule root (the repo with platform/). Prints the size in bytes.
set -eu
ROC=$(bench/get-roc.sh)
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
app=$1; out=$2; shift 2
log=$(timeout 900 "$ROC" build --opt=size --target=wasm32 --no-cache --output="$out" "$@" "$app" 2>&1) || true
echo "$log" | grep -q '^0 errors' || { echo "$log" | head -40 >&2; echo "BUILD FAILED: $app" >&2; exit 1; }
wc -c < "$out"
