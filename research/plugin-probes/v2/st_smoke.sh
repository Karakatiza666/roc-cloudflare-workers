#!/bin/bash
# Smoke test of the 7 storage and Durable Object topics of the roc-syntax-mcp plugin cloudflare-workers.
# For each topic: build the wasm with the pinned nightly, load its manifest with `sync` (the same load check that
# the shim does), and print the Wrangler parts that the manifest needs. The topics must name them in their comments.
# Run: research/plugin-probes/v2/st_smoke.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
ROC=/home/george/dev/Karakatiza666/talon/cloudflare-workers/.cache/nightlies/nightly-2026-10-19-601b54c/roc
topics=/home/george/dev/Karakatiza666/roc-syntax-mcp/plugins/cloudflare-workers/topics
mkdir -p "$here/st_smoke_out" && cd "$here/st_smoke_out"
[ -d .roc-cfw ] || cp -r ~/.cache/roc/packages/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As/js .roc-cfw
for t in objects websockets rpc d1 r2 kv_cache queues; do
	$ROC build --target=wasm32 --no-cache --output=$t.wasm $topics/cfw_$t.roc | tail -2 | head -1
	printf 'name = "smoke-%s"\nmain = "w_%s.js"\ncompatibility_date = "2026-10-01"\ncompatibility_flags = ["enable_request_signal"]\n' $t $t > empty_$t.toml
	echo "=== $t"
	node .roc-cfw/cli.mjs sync --wasm $t.wasm --entry w_$t.js --config empty_$t.toml --force || true
done
