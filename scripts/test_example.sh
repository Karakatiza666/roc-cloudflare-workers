#!/usr/bin/env bash
# Run examples/hello in a copy, with the shim package that a release has (PLAN.md 11b):
# npm install of the .tgz, `wrangler dev --local` and 6 requests, then `wrangler deploy --dry-run`. No deploy.
# Usage: scripts/test_example.sh <app.wasm> <shim .tgz file or URL>. Needs `wrangler` and `npm` on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
wasm=$(realpath "${1:?usage: test_example.sh <app.wasm> <shim .tgz>}")
shim=${2:?usage: test_example.sh <app.wasm> <shim .tgz>}
[[ $shim == http://* || $shim == https://* ]] || shim=$(realpath "$shim")
run=$PWD/.cache/example-run
export TMPDIR=${TMPDIR:-$PWD/.cache/tmp}
mkdir -p "$TMPDIR"
rm -rf "$run"
mkdir -p "$run/project" "$run/site"
cp examples/hello/{worker.js,wrangler.toml,package.json} "$run/project/"
cp "$wasm" "$run/project/app.wasm"
echo "local site" > "$run/site/hello.txt"
export WRANGLER_SEND_METRICS=false CI=1 WRANGLER_LOG_PATH=$run/wrangler-logs XDG_CONFIG_HOME=$run/xdg-config
(cd "$run/project" && npm install --no-audit --no-fund --silent "$shim")
node -e 'const p=require(process.argv[1]); if(!p.dependencies["roc-cloudflare-workers"]) process.exit(1)' "$run/project/package.json"

pids=()
cleanup() { for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null || true; done; }
trap cleanup EXIT
# A site that the route /fetch reads (a second local server: the Worker runs in workerd).
site_port=${SITE_PORT:-8792}
dev_port=${DEV_PORT:-8791}
for port in "$site_port" "$dev_port"; do
  if curl -s -o /dev/null "http://127.0.0.1:$port/"; then echo "FAIL: port $port is in use (set SITE_PORT, DEV_PORT)"; exit 1; fi
done
# Each server is a session leader (`setsid`), and its pid file has its own pid: `cleanup` stops the whole group.
start() { # name, command...
  local name=$1
  shift
  setsid bash -c 'echo $$ > "$0"; exec "$@"' "$run/$name.pid" "$@" > "$run/$name.log" 2>&1 &
  for _ in $(seq 50); do [ -s "$run/$name.pid" ] && break; sleep 0.1; done
  pids+=("$(cat "$run/$name.pid")")
}
start site python3 -m http.server "$site_port" --bind 127.0.0.1 --directory "$run/site"
cd "$run/project"
start dev wrangler dev --local --ip 127.0.0.1 --port "$dev_port"
cd - > /dev/null
base=http://127.0.0.1:$dev_port
for _ in $(seq 120); do curl -sf "$base/" > /dev/null 2>&1 && break; sleep 1; done

fail=0
check() { # path, expected body
  local got
  got=$(curl -s "$base$1" || true)
  if [ "$got" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1: got [$got], want [$2]"; fail=1; fi
}
check / 'hello from Roc'
check /d1 'Ok [{ avatar: [1, 2, 3], id: 1, name: "ann" }]'
check /cbor '16 bytes, Ok({ avatar: [1, 2, 3], id: 7 })'
check "/fetch?url=http://127.0.0.1:$site_port/hello.txt" 'status 200'
check "/fetch?url=http://127.0.0.1:$site_port/nope.txt" 'status 404'
check /nowhere 'no route'
[ "$fail" = 0 ] || { echo "--- wrangler dev log"; tail -n 30 "$run/dev.log"; exit 1; }

# The deploy check: build and validate the bundle, upload nothing.
(cd "$run/project" && wrangler deploy --dry-run --outdir "$run/out" > "$run/dry.log" 2>&1) || { cat "$run/dry.log"; echo "FAIL wrangler deploy --dry-run"; exit 1; }
grep -q "dry-run" "$run/dry.log" && echo "PASS wrangler deploy --dry-run"
