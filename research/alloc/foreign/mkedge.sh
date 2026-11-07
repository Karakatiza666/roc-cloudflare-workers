#!/usr/bin/env bash
# Make a deploy folder edge/<name>/ for the bench Worker (research/edge-bench) from a build <REG>/w2-<name> of app.sh:
# app.wasm, .roc-cfw/ (it takes resumeCheck "off"), wrangler.toml of research/edge-bench (migrations path fixed),
# worker.js with the sums and the global check off (the same for all builds of the A/B, base too).
# Usage: REG=<reg dir> foreign/mkedge.sh <name>...   The lead uploads them (wrangler versions upload); not this script.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
E=$(cd "$D/../../edge-bench" && pwd)
for n in "$@"; do
  o=$D/edge/$n
  rm -rf "$o"; mkdir -p "$o"
  cp "$REG/w2-$n/app.wasm" "$o/"
  rsync -a "$REG/w2-$n/.roc-cfw/" "$o/.roc-cfw/"
  sed 's|migrations_dir = "../../../sql"|migrations_dir = "../../../../../../sql"|' "$E/wrangler.toml" > "$o/wrangler.toml"
  cat > "$o/worker.js" <<'W'
// research/alloc/foreign: an allocator A/B on the bench Worker. Sums and global check off (all builds of the A/B alike).
import app from './app.wasm';
import { makeHandler } from './.roc-cfw/index.js';

export default makeHandler(app, { resumeCheck: 'off', heapCheckEvery: 0, heapCheckWhenIdle: false });
W
  echo "edge $n: $o ($(sha256sum "$o/app.wasm" | cut -c1-12))"
done
