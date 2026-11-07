#!/usr/bin/env bash
# Record one allocator trace per registry scenario (research/regprof): a fresh server for each scenario, on the trace host,
# with CFW_TEST_TRACE (js/test.mjs). POST /__regserve/stop makes the server close the app, and close() writes the trace.
# Usage: W2_DIR=<build dir: app.wasm of the trace platform and .roc-cfw/> scripts/regtrace.sh <scenario[:concurrency[:repeat]]>...
# Output: out/trace_reg_<scenario>[_c<concurrency>].bin and out/reg_<same>.jsonl (the drive log).
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd)
R=$A/../regprof
DRIVE=/home/george/dev/Karakatiza666/talon/research/bench/drive.mjs
for sc in "$@"; do
  IFS=: read -r name conc rep <<< "$sc"; conc=${conc:-1}; rep=${rep:-1}
  tag=$name; [ "$conc" != 1 ] && tag=${name}_c$conc
  out=$A/out/trace_reg_$tag.bin
  rm -f "$out" "$R/state/worker.url"
  CFW_TEST_TRACE=$out MINIFLARE_WORKERD_V8_FLAGS= "$R/serve.sh" > "$A/out/reg_$tag.serve.log" 2>&1 &
  pid=$!
  for _ in $(seq 600); do [ -s "$R/state/worker.url" ] && break; kill -0 $pid 2>/dev/null || { echo "server died: $tag"; exit 1; }; sleep 0.2; done
  node "$DRIVE" --base "$(cat "$R/state/worker.url")" --scenario "$name" --dir "$R/scenarios" --concurrency "$conc" --repeat "$rep" --out "$A/out/reg_$tag.jsonl" --quiet || true
  curl -s -X POST "$(cat "$R/state/worker.url")/__regserve/stop" > /dev/null || true; wait $pid || true
  echo "$tag: $(( $(stat -c %s "$out") / 16 )) records"
done
