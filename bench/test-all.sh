#!/usr/bin/env bash
# Build everything and run every test of the platform, each with `timeout 600`. One line for each test:
# the exit code and the name. Exit 1 when one fails.
# Env: ZIG (Zig 0.17, required), WORKERD (the workerd binary, required), ROC (default: bench/get-roc.sh),
# ROC09 (nightly 10-09, data-first: default `bench/get-roc.sh nightly-2026-10-09-258ab27`).
# The 10-09 apps go to bench/out09 (the test of PLAN.md 4f). `bench/build.sh` copies the glue of its
# compiler into host/: the build with 10-09 runs first and the build with the pinned nightly last,
# so host/roc_platform_abi.zig is the glue of the pinned nightly at the end (checked against its state at the start).
set -uo pipefail
cd "$(dirname "$0")/.."
: "${ZIG:?set ZIG to the Zig 0.17 binary}"
: "${WORKERD:?set WORKERD to the workerd binary}"
export ZIG WORKERD
ROC09=${ROC09:-$(bench/get-roc.sh nightly-2026-10-09-258ab27)}
rc=0
step() { # name, command...
  local name=$1
  shift
  timeout 600 "$@" > ".cache/test-all-$$.log" 2>&1
  local code=$?
  printf '%3d  %s\n' "$code" "$name"
  if [ "$code" -ne 0 ]; then rc=1; tail -n 15 ".cache/test-all-$$.log" | sed 's/^/     | /'; fi
}
mkdir -p .cache
glue0=$(cat host/roc_platform_abi.zig | md5sum)
step "build 10-09 (bench/out09)" env ROC="$ROC09" OUT=bench/out09 bench/build.sh
step "build (bench/build.sh)" bench/build.sh
step "glue is the glue of the pinned nightly (as at the start)" test "$(cat host/roc_platform_abi.zig | md5sum)" = "$glue0"

step "exports-test.mjs (7a: the two export lists, requests on the production build)" node bench/exports-test.mjs bench/out/app_prod.wasm bench/out/app.wasm
step "alloc-test.sh (allocator, grow.mjs, counters.mjs)" bench/alloc-test.sh
step "node-test.mjs" node bench/node-test.mjs bench/out/app.wasm
step "overflow-test.mjs --expect-shared" node bench/overflow-test.mjs bench/out/app_deep.wasm --expect-shared
step "strloop-test.mjs" node bench/strloop-test.mjs bench/out/app_strloop.wasm
for t in log-test oom-test wait-test trapclean-test tasktable-test deadline-test oneinstance-test resume-test; do
  step "$t.mjs" node "bench/$t.mjs" bench/out/app.wasm
done
for w in 16 256 4096; do step "wild.mjs $w" node bench/wild.mjs bench/out/app.wasm "$w"; done
for t in checkheap-test checkevery-test; do step "$t.mjs" node "bench/$t.mjs" bench/out/app.wasm; done
step "stack-test.mjs" node bench/stack-test.mjs bench/out/app_stack.wasm
step "tasks-test.mjs" node bench/tasks-test.mjs
step "cpu-test.mjs" node bench/cpu-test.mjs
step "cancel-test.mjs (--expose-gc)" node --expose-gc --no-concurrent-sparkplug --no-concurrent-recompilation bench/cancel-test.mjs bench/out/app.wasm
step "signal-workerd.mjs" node bench/signal-workerd.mjs
# Memory (PLAN.md 4b to 4f)
step "budget-test.mjs (4b, 4c, 4d, 4e; --expose-gc)" node --expose-gc --no-concurrent-sparkplug --no-concurrent-recompilation bench/budget-test.mjs bench/out/app.wasm
# The two flags: without them `process.exit` hangs in about 1 of 12 runs (a V8 shutdown deadlock, PLAN.md 8e).
step "fallback-budget-test.mjs (4f; --expose-gc)" node --expose-gc --no-concurrent-sparkplug --no-concurrent-recompilation bench/fallback-budget-test.mjs bench/out09/app.wasm
step "budget-workerd.mjs (4e)" node bench/budget-workerd.mjs
step "fallback-workerd.mjs (4f in workerd: 40 requests at once, 3 rounds, no hung request)" node bench/fallback-workerd.mjs
# Log lines, counters, the idle reset (PLAN.md 4g, 4h, 4j). The allocator part (counters.mjs, grow.mjs) is in alloc-test.sh.
step "events-test.mjs (4g, M11 lines and counters; trap in task_cancel)" node bench/events-test.mjs bench/out/app.wasm
step "idle-test.mjs (4h leak counter, 4j idle reset, 12e suspect)" node bench/idle-test.mjs bench/out/app.wasm
# JS shim (PLAN.md 9a, 9b)
step "handler-test.mjs (9a: makeHandler, options, resumeCheck off on the production build)" node bench/handler-test.mjs bench/out/app.wasm bench/out/app_prod.wasm
step "context-test.mjs (9b: the context of each task)" node bench/context-test.mjs bench/out/app.wasm
step "context-workerd.mjs (9b)" node bench/context-workerd.mjs
step "cbor-js-test.mjs (8a: JS codec, RFC 8949 vectors, J1 to J7, refs, Packed, fuzz)" node bench/cbor-js-test.mjs
# The bridge (PLAN.md 8a)
step "cbor_test.zig (8a: the Zig codec, native: HD5 fuzz, HD6, HD7)" sh -c 'cd host && "$ZIG" test cbor_test.zig'
step "cbor-wasm-test.mjs (8a: the Zig codec in the wasm32 host: HD5 corpus, HD6 live bytes, same bytes as JS)" node bench/cbor-wasm-test.mjs bench/out/app.wasm
step "hd4-test.mjs (8a: HD4, the Zig decoder against the Roc oracle bench/hd4/oracle.roc)" node bench/hd4-test.mjs bench/out/app.wasm
step "program-test.mjs (8a: the program interpreter, the result block, pf)" node bench/program-test.mjs
step "bridge-test.mjs (8a: the bridge with app_bridge.wasm: refs, Par, Race, OP7, pf, pins, Packed, status 4, 10c)" node bench/bridge-test.mjs bench/out/app_bridge.wasm
step "bridge-workerd.mjs (8a in workerd)" node bench/bridge-workerd.mjs
# Events (PLAN.md 8b, first half)
step "roc test platform/main.roc (8b: the pure expects of the platform modules)" env ROC_CACHE_DIR="$PWD/.cache/roc" XDG_CACHE_HOME="$PWD/.cache" "${ROC:-$(bench/get-roc.sh)}" test platform/main.roc
step "entry-test.mjs (8b: makeHandler class, Worker, Request, Response, Body, cron rules, Other, crash text; Node)" node bench/entry-test.mjs bench/out/app_events.wasm
step "entry-workerd.mjs (8b in workerd: the scheduled path of Miniflare, a queue event as Other)" node bench/entry-workerd.mjs
# Streams, respond!, the context of a task (PLAN.md 8b second half, 9c, 10a, 10b)
step "stream-test.mjs (8b, 9c, 10a, 10b: stream bodies, respond!, pass_through!, writer!, compress!, wait_until!; Node)" node bench/stream-test.mjs bench/out/app_stream.wasm
step "stream-workerd.mjs (8b, 9c, 10a, 10b in workerd: 50 MB bodies, BodyErr after respond!, waitUntil, the client goes away)" node bench/stream-workerd.mjs
# Native (PLAN.md 8e)
step "native_test.zig (8e: zstd, BLAKE3, SHA-256, the handle table; native)" "$ZIG" test hostlib/native/native_test.zig --cache-dir .cache/native-test
step "native-test.mjs (8e: Native in app_native.wasm: decode, limit, hashes, stream, handles, other task, end of task, OOM, deep stack)" node bench/native-test.mjs bench/out/app_native.wasm
# Phase A modules (PLAN.md 8c, 8d): the conformance app in Miniflare, and the must-not-compile checks of `Secret`
step "conformance/run.mjs (8c, 8d: a route for each function and Io twin in Miniflare)" node conformance/run.mjs bench/out/conformance.wasm
step "conformance/must-not-compile.sh (8c: a Secret in Log fields and in a CBOR encode does not compile)" conformance/must-not-compile.sh
rm -f ".cache/test-all-$$.log"
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "FAIL"
exit "$rc"
