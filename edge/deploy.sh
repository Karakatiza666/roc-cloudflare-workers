#!/usr/bin/env bash
# PLAN.md 11c: deploys the edge app (edge/app.roc, edge/worker.js) as the Worker `rocplat-test-app` on workers.dev, with
# real bindings, and the echo Worker `rocplat-test-echo` (the local server of conformance/run.mjs: /hello, /ten, /slow,
# /echo, /status/<n>). Each resource has the prefix `rocplat-test-` and a row in edge/ledger.md.
#   edge/deploy.sh            make the resources that are missing, then deploy both Workers (needs .cache/edge/app.wasm)
#   edge/deploy.sh delete     delete the Workers and the resources (each delete gets its time in the ledger)
#   The delete removes the queue consumers first: a Worker that consumes a queue, and the queue, do not delete before that.
# Env: CPU_MS (the `limits.cpu_ms` of the app, default none), CRONS (default the 3 crons of the AQ12 test),
# ISOLATE_BYTES (the M3 budget of makeHandler, the 128 MB check), EXTRA_TOML (a file added to the config),
# SRC (the root of another checkout, for example of the tag 0.0.9: its .cache/edge/app.wasm, conformance/ and js/; default this one).
# The bindings are those of the options of conformance/checks/*.mjs, with the prefix `rocplat-test-` on each resource.
set -euo pipefail
cd "$(dirname "$0")/.."
E=$PWD/edge; S=$PWD/.cache/edge/deploy
L=$E/ledger.py
APP=rocplat-test-app ECHO=rocplat-test-echo D1=rocplat-test-d1 R2=rocplat-test-r2 TRACE=rocplat-test-trace KV=rocplat-test-kv KV2=rocplat-test-objflags
# The queues: the name of the local run (conformance/checks/queue.mjs, dec.mjs) with the prefix. edge/worker.js removes it.
QUEUES="jobs texts bin v8 b64j decj decv decvjs"
d1id() { wrangler d1 info "$1" --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).uuid||"")}catch{console.log("")}})' || true; }
kvid() { wrangler kv namespace list 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=s.slice(s.indexOf("["));try{console.log((JSON.parse(j).find(n=>n.title===process.argv[1])||{}).id||"")}catch{console.log("")}})' "$1" || true; }
if [ "${1:-}" = delete ]; then
  # The consumers first (a queue with a consumer, and its consumer Worker, refuse the delete).
  for q in $QUEUES; do wrangler queues consumer remove rocplat-test-$q $APP || true; done
  for w in $APP $ECHO; do wrangler delete --name $w --force && $L del $w || true; done
  for w in rocplat-test-flow rocplat-test-waiter; do wrangler workflows delete $w && $L del $w || true; done
  for q in $QUEUES; do wrangler queues delete rocplat-test-$q && $L del rocplat-test-$q || true; done
  wrangler d1 delete $D1 --skip-confirmation && $L del $D1 || true
  for k in $KV $KV2; do id=$(kvid $k); [ -n "$id" ] && wrangler kv namespace delete --namespace-id "$id" --skip-confirmation && $L del $k || true; done
  # A bucket with an incomplete multipart upload refuses the delete (code 10008): its lifecycle rule aborts it after 1 day.
  for b in $R2 $TRACE; do wrangler r2 bucket delete $b && $L del $b || echo "kept $b: run 'wrangler r2 bucket delete $b' after its lifecycle rule aborts the uploads"; done
  exit 0
fi
SRC=${SRC:-$PWD}
[ -f "$SRC/.cache/edge/app.wasm" ] || { echo "no $SRC/.cache/edge/app.wasm: run edge/build.sh"; exit 1; }
# The resources: an existing one (of this run, in the ledger) or a new one.
ID=$(d1id $D1 || true)
if [ -z "$ID" ]; then wrangler d1 create $D1 >/dev/null; ID=$(d1id $D1); $L add D1 $D1 "$ID"; fi
for b in $R2 $TRACE; do
  if ! wrangler r2 bucket info $b >/dev/null 2>&1; then
    wrangler r2 bucket create $b; $L add R2 $b -
    wrangler r2 bucket lifecycle add $b rocplat-test-abort --abort-multipart-days 1 --force && $L add 'R2 lifecycle rule' "rocplat-test-abort" "on $b: abort incomplete multipart uploads after 1 day (goes with the bucket)"
  fi
done
# The queues (a deploy with a producer of a missing queue fails).
existing=$(wrangler queues list 2>/dev/null || true)
for q in $QUEUES; do
  if ! grep -q " rocplat-test-$q " <<<"$existing"; then wrangler queues create rocplat-test-$q >/dev/null; $L add Queue rocplat-test-$q -; fi
done
for k in $KV $KV2; do
  if [ -z "$(kvid $k || true)" ]; then wrangler kv namespace create $k >/dev/null; $L add KV $k "$(kvid $k)"; fi
done
KVID=$(kvid $KV); KV2ID=$(kvid $KV2)
# The echo Worker.
rm -rf "$S"; mkdir -p "$S/echo" "$S/app/js"
cp "$E/echo.js" "$S/echo/"
cat > "$S/echo/wrangler.toml" <<TOML
name = "$ECHO"
main = "echo.js"
compatibility_date = "2026-10-01"
workers_dev = true
TOML
new_echo=0; wrangler deployments list --name $ECHO >/dev/null 2>&1 || new_echo=1
(cd "$S/echo" && wrangler deploy)
[ $new_echo = 1 ] && $L add Worker $ECHO "https://$ECHO.bellup.workers.dev"
# The app Worker: no_bundle, the modules as conformance/run.mjs names them.
cp "$SRC/.cache/edge/app.wasm" "$S/app/app.wasm"
cp "$E/worker.js" "$S/app/worker.js"
# The conformance worker, under the name that edge/worker.js imports. ISOLATE_BYTES: the M3 budget of makeHandler.
cp "$SRC/conformance/worker.js" "$S/app/conformance-worker.js"
if [ -n "${ISOLATE_BYTES:-}" ]; then
  grep -q 'makeHandler(app, { ' "$S/app/conformance-worker.js" || { echo "no makeHandler call to change"; exit 1; }
  sed -i "s/makeHandler(app, { /makeHandler(app, { isolateBytes: $ISOLATE_BYTES, /" "$S/app/conformance-worker.js"
fi
cp "$SRC/conformance/bindings.js" "$S/app/"
cp "$SRC"/js/*.js "$S/app/js/"
cp -r "$SRC/conformance/assets" "$S/app/assets"
# The binding of a queue and the max_batch_size of its consumer (conformance/checks/queue.mjs, dec.mjs).
binding_of() { case $1 in v8) echo V8Q ;; *) echo "$1" | tr a-z A-Z ;; esac; }
batch_of() { case $1 in jobs|decj|decv|decvjs) echo 20 ;; *) echo 5 ;; esac; }
CRONS=${CRONS:-'"*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *"'}
{
cat <<TOML
name = "$APP"
main = "worker.js"
compatibility_date = "2026-10-01"
compatibility_flags = ["enable_request_signal", "global_fetch_strictly_public"]
workers_dev = true
no_bundle = true
rules = [
  { type = "ESModule", globs = ["bindings.js", "conformance-worker.js", "js/*.js"] },
  { type = "CompiledWasm", globs = ["*.wasm"] },
]
services = [
  { binding = "SELF", service = "$APP" },
  { binding = "ADMIN", service = "$APP", entrypoint = "Admin" },
  { binding = "AFTER", service = "$APP", entrypoint = "After" },
]
[triggers]
crons = [ $CRONS ]
[observability]
enabled = true
[version_metadata]
binding = "V"
[assets]
directory = "assets"
binding = "ASSETS"
run_worker_first = true
[vars]
TEXT_VAR = "hello"
JSON_TEXT = '{"name":"b","n":4}'
SECRET_VAR = "hunter2"
[vars.JSON_VAR]
name = "a"
n = 3
[[d1_databases]]
binding = "DB"
database_name = "$D1"
database_id = "$ID"
[[r2_buckets]]
binding = "BUCKET"
bucket_name = "$R2"
[[r2_buckets]]
binding = "TRACE"
bucket_name = "$TRACE"
[[analytics_engine_datasets]]
binding = "STATS"
dataset = "rocplat_test_conformance"
[[kv_namespaces]]
binding = "KV"
id = "$KVID"
[[kv_namespaces]]
binding = "OBJFLAGS"
id = "$KV2ID"
[[ratelimits]]
name = "LIMITER"
namespace_id = "1001"
simple = { limit = 2, period = 60 }
[[durable_objects.bindings]]
name = "COUNTERS"
class_name = "Counter"
[[durable_objects.bindings]]
name = "STORES"
class_name = "Store"
[[durable_objects.bindings]]
name = "FLAKY"
class_name = "Flaky"
[[durable_objects.bindings]]
name = "SLOW"
class_name = "Slow"
[[durable_objects.bindings]]
name = "TICKERS"
class_name = "Ticker"
[[durable_objects.bindings]]
name = "ROOMS"
class_name = "Room"
$(for q in $QUEUES; do printf '[[queues.producers]]\nbinding = "%s"\nqueue = "rocplat-test-%s"\n' "$(binding_of $q)" $q; done)
[[queues.consumers]]
queue = "rocplat-test-jobs"
max_batch_size = 20
max_batch_timeout = 1
max_retries = 3
retry_delay = 0
$(for q in $QUEUES; do [ $q = jobs ] || printf '[[queues.consumers]]\nqueue = "rocplat-test-%s"\nmax_batch_size = %s\nmax_batch_timeout = 1\n' $q "$(batch_of $q)"; done)
[[workflows]]
name = "rocplat-test-flow"
binding = "FLOW"
class_name = "Flow"
[[workflows]]
name = "rocplat-test-waiter"
binding = "WAIT"
class_name = "Waiter"
[[migrations]]
tag = "v1"
new_sqlite_classes = ["Counter", "Store", "Flaky", "Slow", "Ticker", "Room"]
TOML
[ -n "${CPU_MS:-}" ] && printf '[limits]\ncpu_ms = %s\n' "$CPU_MS"
[ -n "${EXTRA_TOML:-}" ] && cat "$EXTRA_TOML"
} > "$S/app/wrangler.toml"
new_app=0; wrangler deployments list --name $APP >/dev/null 2>&1 || new_app=1
(cd "$S/app" && wrangler deploy)
if ! grep -q 'rocplat-test-flow' "$E/ledger.md"; then for w in rocplat-test-flow rocplat-test-waiter; do $L add Workflow $w "made by the deploy of $APP"; done; fi
[ $new_app = 1 ] && $L add Worker $APP "https://$APP.bellup.workers.dev (crons: $CRONS)"
echo "deployed: https://$APP.bellup.workers.dev"
