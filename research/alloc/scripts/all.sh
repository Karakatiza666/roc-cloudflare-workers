#!/usr/bin/env bash
# Run every benchmark for every version, one at a time, into out/all/. These are the README tables.
# Usage: scripts/all.sh [versions...] (default: v0 v1 v2 v3 v5 v6 v7). Run on a quiet machine.
# Needs: build.sh and replay/build.sh for the versions, and the traces in out/ (trace.mjs, synth.mjs).
set -uo pipefail
cd "$(dirname "$0")/.."
V=${*:-v0 v1 v2 v3 v5 v6 v7}
O=out/all
mkdir -p "$O"
date > "$O/date.txt"; uptime >> "$O/date.txt"; node --version >> "$O/date.txt"
# Lines of code: no blank lines, no comment lines.
for v in $V; do echo "$v $(grep -cvE '^\s*(//.*)?$' versions/$v.zig)"; done > "$O/loc.txt"
# Allocator CPU and memory, no app code (replay of recorded and synthetic traces).
for t in 2000_6 200_40 synth_med synth_mix synth_grow; do
  node scripts/replay.mjs "$t" 7 $V > "$O/replay_$t.txt" 2>&1
done
# Full app: variant A, B, B sum 1, B sum 2 at 1, 16, 64 requests at once.
node scripts/ab.mjs 3000 $V > "$O/ab.txt" 2>&1
# Full app, fresh process for each version and first request id.
for id in 1 300 100000 1000000; do for v in $V; do ID0=$id node scripts/peak.mjs "$v"; done; done > "$O/peak.txt" 2>&1
# String loop (B5).
for v in $V; do echo "$v $(node scripts/strloop.mjs "$v" '2 0 20000' '2 0 80000' 2>&1 | tr '\n' ' ')"; done > "$O/strloop.txt"
# Wild writes, then an unclean trap: wrong bodies with status 200.
for v in $V; do for s in 0 1 2; do for w in 16 256 4096; do
  echo "$v sum $s words $w: $(SUM=$s node scripts/wild.mjs "$v" "$w" 20000 0.005 20 2>&1 | tail -1)"
done; done; done > "$O/wild.txt"
date >> "$O/date.txt"
