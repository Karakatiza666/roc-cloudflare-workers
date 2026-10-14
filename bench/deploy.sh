#!/bin/bash
# Q13: deploy the bench to Cloudflare as 4 Workers, the same setup as config-{a,b,j}.capnp:
#   talon-bench-echo, and talon-bench-{a,b,j} with the ECHO service binding and VARIANT.
# Usage: bench/deploy.sh          deploy (needs `wrangler login` and bench/out/ from build.sh)
#        bench/deploy.sh delete   remove the 4 Workers
set -e
B=$(cd "$(dirname "$0")" && pwd); S=$B/../.cache/deploy
if [ "$1" = delete ]; then
  for w in a b j echo; do wrangler delete --name talon-bench-$w --force; done
  exit 0
fi
rm -rf $S; mkdir -p $S/echo
cp $B/echo.js $S/echo/
cat > $S/echo/wrangler.toml <<EOF
name = "talon-bench-echo"
main = "echo.js"
compatibility_date = "2026-10-01"
workers_dev = true
EOF
(cd $S/echo && wrangler deploy)
for v in a b j; do
  d=$S/$v; mkdir -p $d
  cp $B/worker.js $B/core.js $B/out/app.wasm $B/out/app_pad.wasm $d/
  # no_bundle: upload the modules as they are, named as in the capnp configs ('app.wasm', 'core.js').
  cat > $d/wrangler.toml <<EOF
name = "talon-bench-$v"
main = "worker.js"
compatibility_date = "2026-10-01"
workers_dev = true
no_bundle = true
rules = [
  { type = "ESModule", globs = ["core.js"] },
  { type = "CompiledWasm", globs = ["*.wasm"] },
]
services = [{ binding = "ECHO", service = "talon-bench-echo" }]
[vars]
VARIANT = "$v"
PAD = "0"
EOF
  (cd $d && wrangler deploy)
done
