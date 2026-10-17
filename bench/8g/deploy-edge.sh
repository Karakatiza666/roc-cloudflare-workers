#!/usr/bin/env bash
# PLAN.md step 8g, edge part (11c): deploys the measure app (`app.roc`, `worker.js`) as the Worker `talon-bench-8g` with a D1
# database `talon-8g`, makes the table `releases` (200 rows), and prints the URL.
#   bench/8g/deploy-edge.sh            deploy (needs `wrangler login`, a plan with a CPU limit above 10 ms, and bench/8g/out/app.wasm
#                                      from `bench/8g/build.sh default`). Env: RESUME=always|off (the shim option `resumeCheck`)
#   bench/8g/deploy-edge.sh delete     remove the Worker and the database
#   bench/8g/deploy-edge.sh dry        only `wrangler deploy --dry-run` (no login): checks the files and the config
# Then: EDGE_URL=https://talon-bench-8g.<account>.workers.dev node bench/8g/run-edge.mjs
set -euo pipefail
B=$(cd "$(dirname "$0")" && pwd)
S=$B/../../.cache/deploy-8g
RESUME=${RESUME:-always}
if [ "${1:-}" = delete ]; then
  wrangler delete --name talon-bench-8g --force
  wrangler d1 delete talon-8g --skip-confirmation
  exit 0
fi
rm -rf "$S"
mkdir -p "$S/js"
cp "$B/out/app.wasm" "$B/parts.js" "$S/"
sed "s/__RESUME__/$RESUME/g" "$B/worker.js" > "$S/worker.js"
cp "$B"/../../js/*.js "$S/js/"
if [ "${1:-}" = dry ]; then
  ID=00000000-0000-0000-0000-000000000000
else
  # The database id: an existing one, or a new one.
  ID=$(wrangler d1 info talon-8g --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).uuid||"")}catch{console.log("")}})' || true)
  if [ -z "$ID" ]; then
    wrangler d1 create talon-8g >/dev/null
    ID=$(wrangler d1 info talon-8g --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).uuid))')
  fi
fi
# no_bundle: the modules go up as they are (as bench/deploy.sh), `limits.cpu_ms`: a request of one second of CPU.
cat > "$S/wrangler.toml" <<TOML
name = "talon-bench-8g"
main = "worker.js"
compatibility_date = "2026-10-01"
compatibility_flags = ["enable_request_signal"]
workers_dev = true
no_bundle = true
rules = [
  { type = "ESModule", globs = ["parts.js", "js/*.js"] },
  { type = "CompiledWasm", globs = ["*.wasm"] },
]
[limits]
cpu_ms = 30000
[[d1_databases]]
binding = "DB"
database_name = "talon-8g"
database_id = "$ID"
TOML
cd "$S"
if [ "${1:-}" = dry ]; then
  wrangler deploy --dry-run --outdir "$S/dry"
  exit 0
fi
wrangler deploy
echo "Make the table: curl -s https://talon-bench-8g.<account>.workers.dev/__setup?rows=200   (must print 200)"
