#!/usr/bin/env bash
# Make a copy of the platform with the trace host (zig build -Dtrace=true): <dir>/main.roc and <dir>/targets/wasm32/host.wasm.
# An app that names <dir>/main.roc as its platform gets a wasm that calls js_trace at each allocator call (js/trace.js).
# The copy is only for benches: the release host in platform/targets/ is not changed. Usage: research/alloc/trace-platform.sh <dir>
# Env: ZIG (Zig 0.17, required).
set -euo pipefail
: "${ZIG:?set ZIG to the Zig 0.17 binary}"
R=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$1"
D=$(cd "$1" && pwd)
cd "$R"
P=$R/.cache/trace-prefix
rm -rf "$P"
"$ZIG" build -Dtrace=true --prefix "$P"
rm -rf "$D"
mkdir -p "$D/targets/wasm32"
rsync -a --exclude targets "$R/platform/" "$D/"
cp "$P/host-trace.wasm" "$D/targets/wasm32/host.wasm"
echo "trace platform: $D/main.roc"
