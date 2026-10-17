#!/usr/bin/env bash
# conformance/run.mjs leaves no temp dir (PLAN.md 8f, after the merge of part 1): a normal run, a run that fails at the
# start (FAIL start: a file that is not wasm), and a run killed with SIGTERM. Each run gets a caller TMPDIR of its own
# (in .cache/tmp, not /tmp): a `miniflare-*` dir in it, or a `.cache/tmp/run-<pid>` dir after the run, is a FAIL.
#   conformance/tmpdir-test.sh [app.wasm]      (default: bench/out/conformance.wasm). Exit 1 on a failure.
set -u
cd "$(dirname "$0")/.."
wasm=${1:-bench/out/conformance.wasm}
base=.cache/tmp/tmpdir-test
rm -rf "$base"
mkdir -p "$base"
printf 'not wasm' > "$base/bad.wasm"
rc=0
check() { # name, caller TMPDIR, pid of the run
  local left
  left=$( (ls -d "$2"/miniflare-* ".cache/tmp/run-$3" 2>/dev/null) | tr '\n' ' ')
  if [ -n "$left" ]; then echo "FAIL $1: left $left"; rc=1; else echo "PASS $1"; fi
}

mkdir -p "$base/normal"
TMPDIR=$PWD/$base/normal node conformance/run.mjs "$wasm" 'http get!' > "$base/normal.log" 2>&1 &
p=$!
wait $p
code=$?
[ "$code" -eq 0 ] || { echo "FAIL normal: exit $code"; rc=1; }
check "normal run" "$base/normal" $p

mkdir -p "$base/start"
TMPDIR=$PWD/$base/start node conformance/run.mjs "$base/bad.wasm" > "$base/start.log" 2>&1 &
p=$!
wait $p
grep -q '^FAIL start' "$base/start.log" || { echo "FAIL start run: no FAIL start line"; rc=1; }
check "FAIL start run" "$base/start" $p

# SIGTERM after Miniflare is up: its temp dir is in the run dir then.
mkdir -p "$base/term"
TMPDIR=$PWD/$base/term node conformance/run.mjs "$wasm" > "$base/term.log" 2>&1 &
p=$!
for _ in $(seq 1 120); do
  grep -q '^PASS' "$base/term.log" && break
  sleep 0.5
done
kill -TERM $p
wait $p
check "run killed with SIGTERM" "$base/term" $p

[ "$rc" -eq 0 ] && rm -rf "$base"
exit $rc
