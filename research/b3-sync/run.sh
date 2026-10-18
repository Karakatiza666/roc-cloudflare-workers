#!/usr/bin/env bash
# Step 8h wave B, issue 5: `roc-cloudflare-workers sync` on a project with one Durable Object class, one D1 database and
# one cron (app.roc), then the project in `wrangler dev --local`. Needs wrangler on PATH. Deploys nothing.
#   1. a project with app.wasm and a wrangler.toml of 4 lines: sync writes worker.js, prints the missing parts, exit 1
#   2. the printed parts added to wrangler.toml: sync gives exit 0
#   3. wrangler dev: the routes, a cron run by /cdn-cgi/local/scheduled (its handler bumps the counter)
#   4. the D1 binding renamed in wrangler.toml: the load of the Worker fails with the message of the shim
#   5. DB is a KV namespace in wrangler.toml: the load fails, DB is not a D1 database
set -euo pipefail
cd "$(dirname "$0")/../.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
export WRANGLER_SEND_METRICS=false CI=1
run=$PWD/.cache/b3-sync
rm -rf "$run"
mkdir -p "$run/project/node_modules"
ln -s "$PWD/js" "$run/project/node_modules/roc-cloudflare-workers"
"$ROC" build --opt=speed --target=wasm32 --no-cache --output="$run/project/app.wasm" research/b3-sync/app.roc > "$run/build.log" 2>&1
cli="node $PWD/js/cli.mjs"
cd "$run/project"
cat > wrangler.toml <<'TOML'
name = "b3-sync"
main = "worker.js"
compatibility_date = "2026-10-01"
compatibility_flags = ["enable_request_signal"]
TOML
echo "== 1. sync on a config of 4 lines"
set +e; $cli sync > ../sync1.txt; code=$?; set -e
cat ../sync1.txt
[ $code = 1 ] || { echo "FAIL: exit $code, want 1"; exit 1; }
echo "== worker.js"; cat worker.js
echo "== 2. the printed parts added"
sed -n '/^Add to the end/,$p' ../sync1.txt | tail -n +2 >> wrangler.toml
cat wrangler.toml
$cli sync
echo "== 3. wrangler dev"
port=${DEV_PORT:-8794}
setsid wrangler dev --local --ip 127.0.0.1 --port "$port" > ../dev.log 2>&1 &
dev=$!
trap 'kill -- -$dev 2>/dev/null || true' EXIT
for _ in $(seq 60); do curl -sf "http://127.0.0.1:$port/d1" > /dev/null 2>&1 && break; sleep 1; done
fail=0
check() { got=$(curl -s "http://127.0.0.1:$port$1" || true); if [ "$got" = "$2" ]; then echo "PASS $1 $got"; else echo "FAIL $1: [$got], want [$2]"; fail=1; fi; }
check /d1 "d1 42"
check / "count 0"
curl -s "http://127.0.0.1:$port/cdn-cgi/local/scheduled?cron=*/5+*+*+*+*&format=json" || true; echo
check / "count 1"
kill -- -$dev 2>/dev/null || true
sleep 1
echo "== 4. the binding DB renamed to DB2"
sed -i 's/^binding = "DB"$/binding = "DB2"/' wrangler.toml
set +e; $cli sync > ../sync4.txt; code=$?; set -e
grep -E 'missing|wrong' ../sync4.txt
[ $code = 1 ] || { echo "FAIL: sync exit $code, want 1"; fail=1; }
setsid wrangler dev --local --ip 127.0.0.1 --port "$port" > ../dev4.log 2>&1 &
dev=$!
for _ in $(seq 30); do grep -q "env has no DB\|Ready on" ../dev4.log && break; sleep 1; done
sleep 2
curl -s "http://127.0.0.1:$port/d1" > ../d1-4.txt 2>&1 || true
if grep -q "env has no DB" ../dev4.log; then echo "PASS the load error: $(grep -m1 -o 'DB (d1): env has no DB[^.]*' ../dev4.log)"; else echo "FAIL: no load error in dev4.log"; tail -20 ../dev4.log; fail=1; fi
kill -- -$dev 2>/dev/null || true
sleep 1
echo "== 5. DB is a KV namespace"
printf '\n[[kv_namespaces]]\nbinding = "DB"\nid = "00000000000000000000000000000000"\n' >> wrangler.toml
set +e; $cli sync > ../sync5.txt; code=$?; set -e
grep -E 'missing|wrong|DB' ../sync5.txt
setsid wrangler dev --local --ip 127.0.0.1 --port "$port" > ../dev5.log 2>&1 &
dev=$!
for _ in $(seq 30); do grep -q "is not a D1\|Ready on" ../dev5.log && break; sleep 1; done
sleep 2
if grep -q "env.DB is not a D1 database" ../dev5.log; then echo "PASS the load error: $(grep -m1 -o 'DB (d1): env.DB is not[^.]*' ../dev5.log)"; else echo "FAIL: no kind error in dev5.log"; tail -20 ../dev5.log; fail=1; fi
exit $fail
