#!/usr/bin/env bash
# Mutation check of the v8 hot paths in hostlib/alloc.zig: apply one mutation (mut/<name>.py edits the file), run the
# allocator tests (bench/alloc-test.sh), then restore the file. Usage: ZIG=<zig 0.17> research/alloc/mut/run.sh <name>...
set -uo pipefail
cd "$(dirname "$0")/../../.."
F=hostlib/alloc.zig
for m in "$@"; do
  cp $F .cache/alloc.zig.mut-save
  python3 research/alloc/mut/mut.py "$m" $F || { cp .cache/alloc.zig.mut-save $F; exit 2; }
  out=$(bench/alloc-test.sh 2>&1); rc=$?
  cp .cache/alloc.zig.mut-save $F; rm -f .cache/alloc.zig.mut-save
  echo "== $m: alloc-test.sh exit $rc"
  echo "$out" | grep -E "FAIL|panic|unreachable|error" | head -5
done
