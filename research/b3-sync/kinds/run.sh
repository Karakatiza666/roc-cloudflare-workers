#!/usr/bin/env bash
# The kind check of js/bindings.js in wrangler dev: prints the JSON of worker.js. Deploys nothing.
set -euo pipefail
cd "$(dirname "$0")"
export WRANGLER_SEND_METRICS=false CI=1
port=${DEV_PORT:-8795}
log=../../../.cache/b3-kinds.log
setsid wrangler dev --local --ip 127.0.0.1 --port "$port" > "$log" 2>&1 &
dev=$!
trap 'kill -- -$dev 2>/dev/null || true' EXIT
for _ in $(seq 60); do curl -sf "http://127.0.0.1:$port/" > /dev/null 2>&1 && break; sleep 1; done
curl -s "http://127.0.0.1:$port/" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);for(const[k,v]of Object.entries(j))console.log(k.padEnd(10),v.kind.padEnd(11),JSON.stringify(v.own),"also:",v.alsoPasses.join(","))})' || tail -30 "$log"
