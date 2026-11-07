#!/usr/bin/env bash
# One phase of the edge A/B (README.md, "Edge"): the requests of research/bench/drive.mjs to the bench Worker while it runs
# two versions at 50/50, then (after 5 min, for the analytics) CPU per version and D1 rows of the window (edgecpu.mjs).
# Usage: foreign/edgerun.sh <phase> <scenario> <repeat> [concurrency=4]. Env from talon/.env (account id, token): never printed.
# Output: out-edge-<phase>.jsonl (each request), out-edge-<phase>.json (per version), out-edge-<phase>.txt.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$D/../../../.." && pwd)
from=$(date -u +%Y-%m-%dT%H:%M:%SZ)
node "$T/research/bench/drive.mjs" --base https://talon-registry-bench.bellup.workers.dev --scenario "$2" --repeat "$3" \
  --concurrency "${4:-4}" --out "$D/out-edge-$1.jsonl" --quiet
to=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "phase $1: $from to $to"
sleep 300
set -a; . "$T/.env"; set +a
node "$D/edgecpu.mjs" --from "$from" --to "$to" --json "$D/out-edge-$1.json" --d1 ddcc66e8-a4df-4e4b-aee9-ac4a5fb1ebaa | tee "$D/out-edge-$1.txt"
