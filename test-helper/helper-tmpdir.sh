#!/usr/bin/env bash
# H8 of research/design-notes/test-helper.md 7 (TH9): SIGTERM and SIGINT during a run remove the run dirs of startApp
# (cfw-test-<pid>-<n>, and the TMPDIR parent cfw-test-<pid> with the miniflare-* dirs), as conformance/tmpdir-test.sh.
# Usage: test-helper/helper-tmpdir.sh [helper.wasm]    (default: .cache/th/helper.wasm)
set -euo pipefail
cd "$(dirname "$0")/.."
wasm=$(realpath "${1:-.cache/th/helper.wasm}")
tmp=$PWD/.cache/th/tmpdir-test
fail=0
for sig in TERM INT; do
  rm -rf "$tmp"
  mkdir -p "$tmp"
  TMPDIR=$tmp node test-helper/tmpdir-child.mjs "$wasm" > "$tmp/out.log" 2>&1 &
  pid=$!
  for _ in $(seq 100); do grep -q ready "$tmp/out.log" 2>/dev/null && break; sleep 0.2; done
  before=$(ls "$tmp" | grep -c "^cfw-test-$pid" || true)
  kill -"$sig" "$pid"
  wait "$pid" || true
  after=$(ls "$tmp" | grep -c "^cfw-test-" || true)
  if [ "$before" -ge 3 ] && [ "$after" = 0 ]; then echo "PASS SIG$sig: $before run dirs during the run, 0 after"; else echo "FAIL SIG$sig: $before run dirs during the run, $after after: $(ls "$tmp")"; fail=1; fi
done
rm -rf "$tmp"
exit $fail
