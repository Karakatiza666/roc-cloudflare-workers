#!/usr/bin/env bash
# PLAN.md 8g, edge part (11c): bench/8g/deploy-edge.sh with the names of the edge run (`rocplat-test-8g`, D1
# `rocplat-test-8g-d1`), the ledger (edge/ledger.md), and no `limits.cpu_ms` (the Free plan refuses it: code 100328).
#   edge/deploy-8g.sh           deploy (needs bench/8g/out/app.wasm from `bench/8g/build.sh default`). Env: RESUME=always|off
#   edge/deploy-8g.sh delete    remove the Worker and the database
set -euo pipefail
cd "$(dirname "$0")/.."
B=$PWD/bench/8g; S=$PWD/.cache/edge/deploy-8g; L=$PWD/edge/ledger.py
W=rocplat-test-8g DB=rocplat-test-8g-d1
RESUME=${RESUME:-always}
d1id() { wrangler d1 info "$1" --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).uuid||"")}catch{console.log("")}})' || true; }
if [ "${1:-}" = delete ]; then
  wrangler delete --name $W --force && $L del $W || true
  wrangler d1 delete $DB --skip-confirmation && $L del $DB || true
  exit 0
fi
rm -rf "$S"; mkdir -p "$S/js"
cp "$B/out/app.wasm" "$B/parts.js" "$S/"
sed "s/__RESUME__/$RESUME/g" "$B/worker.js" > "$S/worker.js"
cp js/*.js "$S/js/"
ID=$(d1id $DB)
if [ -z "$ID" ]; then wrangler d1 create $DB >/dev/null; ID=$(d1id $DB); $L add D1 $DB "$ID"; fi
cat > "$S/wrangler.toml" <<TOML
name = "$W"
main = "worker.js"
compatibility_date = "2026-10-01"
compatibility_flags = ["enable_request_signal"]
workers_dev = true
no_bundle = true
rules = [
  { type = "ESModule", globs = ["parts.js", "js/*.js"] },
  { type = "CompiledWasm", globs = ["*.wasm"] },
]
[[d1_databases]]
binding = "DB"
database_name = "$DB"
database_id = "$ID"
TOML
new=0; wrangler deployments list --name $W >/dev/null 2>&1 || new=1
(cd "$S" && wrangler deploy)
[ $new = 1 ] && $L add Worker $W "https://$W.bellup.workers.dev"
echo "deployed: https://$W.bellup.workers.dev (resumeCheck $RESUME)"
