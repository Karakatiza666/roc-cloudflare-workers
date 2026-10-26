#!/usr/bin/env bash
# Run examples/hello in a copy, with the shim files that a release has (PLAN.md 11b, research/talon-fit/TRANSITION.md 6.1):
# copy js/ to <project>/.roc-cfw/, `node .roc-cfw/cli.mjs sync` (it writes worker.js), `sync --check`,
# `wrangler dev --local` and 6 requests, then `wrangler deploy --dry-run`. No deploy. No npm, no Talon, no helper.
# Usage: scripts/test_example.sh <app.wasm> [js directory]. The default js directory is js/ of this repository. The
# test of a bundle passes the js/ of the unpacked bundle. Needs `wrangler` and `node` on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
wasm=$(realpath "${1:?usage: test_example.sh <app.wasm> [js directory]}")
jsdir=$(realpath "${2:-js}")
{ test -f "$jsdir/cli.mjs" && test -f "$jsdir/index.js"; } || { echo "FAIL: $jsdir is not a js/ directory (no cli.mjs, no index.js)"; exit 1; }
run=$PWD/.cache/example-run
export TMPDIR=${TMPDIR:-$PWD/.cache/tmp}
mkdir -p "$TMPDIR"
rm -rf "$run"
mkdir -p "$run/project" "$run/site"
cp examples/hello/wrangler.toml "$run/project/"
cp -r "$jsdir" "$run/project/.roc-cfw"
cp "$wasm" "$run/project/app.wasm"
echo "local site" > "$run/site/hello.txt"
export WRANGLER_SEND_METRICS=false CI=1 WRANGLER_LOG_PATH=$run/wrangler-logs XDG_CONFIG_HOME=$run/xdg-config
# `sync` writes worker.js (a project has none yet): its import is ./.roc-cfw/index.js, the relative path to the
# directory of cli.mjs. It checks wrangler.toml, which has the parts of the manifest (the D1 binding of
# `Worker.new bindings`). The second call finds the file as `sync` writes it. The file is the one of
# examples/hello, but for the import line (the example imports ../../js/index.js).
(cd "$run/project" && node .roc-cfw/cli.mjs sync)
(cd "$run/project" && node .roc-cfw/cli.mjs sync --check)
grep -q "^import { makeHandler } from './.roc-cfw/index.js';$" "$run/project/worker.js" || { echo "FAIL: worker.js does not import ./.roc-cfw/index.js"; exit 1; }
diff <(sed "s|'./.roc-cfw/index.js'|'../../js/index.js'|" "$run/project/worker.js") examples/hello/worker.js > /dev/null || { echo "FAIL: worker.js of sync is not examples/hello/worker.js"; exit 1; }

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
