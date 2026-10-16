#!/usr/bin/env bash
# Run bench/fallback-budget-test.mjs N times (default 10) while two copies of bench/sumcost.mjs load the CPU
# (PLAN.md 8e, "Fallback queue in workerd"). Prints the pass count. The two V8 flags avoid a hang of `process.exit`
# (PLAN.md 8e); with FLAGS_OFF=1 the test runs without them. Usage: bench/flaky-load.sh [N] [test.mjs]
set -u
cd "$(dirname "$0")/.."
N=${1:-10}
T=${2:-bench/fallback-budget-test.mjs}
FLAGS="--no-concurrent-sparkplug --no-concurrent-recompilation"
[ "${FLAGS_OFF:-}" = 1 ] && FLAGS=""
node bench/sumcost.mjs bench/out/app.wasm 100000 50 > /dev/null 2>&1 &
p1=$!
node bench/sumcost.mjs bench/out/app.wasm 100000 50 > /dev/null 2>&1 &
p2=$!
trap 'kill $p1 $p2 2>/dev/null' EXIT
sleep 2
pass=0
for i in $(seq 1 "$N"); do
  if timeout 120 node --expose-gc $FLAGS "$T" bench/out09/app.wasm > ".cache/flaky-$i.log" 2>&1; then pass=$((pass + 1)); r=pass; else r=FAIL; fi
  echo "run $i: $r (load $(cut -d' ' -f1 /proc/loadavg))"
done
echo "passed $pass of $N"
