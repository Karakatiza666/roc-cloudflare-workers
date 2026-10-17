#!/usr/bin/env bash
# PLAN.md 8f part 1, 11c: the edge app with the compatibility date 2025-06-01 (before 2026-02-24, when `deleteAll` keeps
# the alarm) as the Worker `rocplat-test-old`, with only the Durable Object class `Counter` (binding COUNTERS).
#   edge/deploy-old.sh          deploy (needs .cache/edge/app.wasm), then GET /objects/counter/delete_all?name=old
#   edge/deploy-old.sh delete   delete the Worker
set -euo pipefail
cd "$(dirname "$0")/.."
S=$PWD/.cache/edge/deploy-old; L=$PWD/edge/ledger.py; W=rocplat-test-old
if [ "${1:-}" = delete ]; then wrangler delete --name $W --force && $L del $W; exit 0; fi
rm -rf "$S"; mkdir -p "$S/js"
cp .cache/edge/app.wasm edge/worker.js conformance/bindings.js "$S/"
cp js/*.js "$S/js/"
cat > "$S/wrangler.toml" <<TOML
name = "$W"
main = "worker.js"
compatibility_date = "2025-06-01"
compatibility_flags = ["enable_request_signal"]
workers_dev = true
no_bundle = true
rules = [
  { type = "ESModule", globs = ["bindings.js", "js/*.js"] },
  { type = "CompiledWasm", globs = ["*.wasm"] },
]
[[durable_objects.bindings]]
name = "COUNTERS"
class_name = "Counter"
[[migrations]]
tag = "v1"
new_sqlite_classes = ["Counter"]
TOML
new=0; wrangler deployments list --name $W >/dev/null 2>&1 || new=1
(cd "$S" && wrangler deploy)
[ $new = 1 ] && $L add Worker $W "https://$W.bellup.workers.dev (compatibility date 2025-06-01)"
echo "deployed: https://$W.bellup.workers.dev"
