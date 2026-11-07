#!/usr/bin/env bash
# Build the heavy-task app (app/main.roc) on a variant host: out/<v>/pf (platform copy) and out/<v>/app (app.wasm, .roc-cfw/,
# worker.js, wrangler.toml). Variants: base (hostlib/alloc.zig), fa_dl, fa_zig (../fa.zig backends). Sums off (SUM_OFF=1) in all.
# The steps of ../../variant-platform.sh, with its own work dir (.cache/hostvar-heavy), so builds of other sessions do not collide.
# Usage: ZIG=<zig 0.17> heavy/build.sh <variant>...
set -euo pipefail
: "${ZIG:?set ZIG to the Zig 0.17 binary}"
H=$(cd "$(dirname "$0")" && pwd)
F=$(cd "$H/.." && pwd)
R=$(cd "$H/../../../.." && pwd)
ROC=$R/.cache/nightlies/nightly-2026-10-31-f7bef6b/roc
for v in "$@"; do
  EXTRA_ZIG=""; EXTRA_OBJ=""
  case $v in
    base) src=$R/hostlib/alloc.zig ;;
    fa_*) b=${v#fa_}; "$F/gen.sh" "$b"; src=$F/gen/fa_$b.zig; EXTRA_ZIG=$F/fa_tl.zig
          [ -f "$F/gen/$b.o" ] && EXTRA_OBJ=$F/gen/$b.o ;;
    *.zig) src=$H/$v; v=$(basename "$v" .zig) ;;
    *) echo "unknown variant $v"; exit 2 ;;
  esac
  W=$R/.cache/hostvar-heavy
  rm -rf "$W"; mkdir -p "$W"
  cp "$R/build.zig" "$W/"
  rsync -a "$R/host" "$R/hostlib" "$R/platform" "$W/"
  cp "$src" "$W/hostlib/alloc.zig"
  for f in $EXTRA_ZIG; do cp "$f" "$W/hostlib/"; done
  grep -q 'if (!BENCH and m == 0) return 0;' "$W/host/host.zig"
  sed -i 's/if (!BENCH and m == 0) return 0;/_ = BENCH; \/\/ SUM_OFF: research build/' "$W/host/host.zig"
  (cd "$W" && ZIG_GLOBAL_CACHE_DIR=$R/.cache/zig ZIG_LOCAL_CACHE_DIR=$W/.zig-cache "$ZIG" build)
  if [ -n "$EXTRA_OBJ" ]; then
    "$ZIG" wasm-ld -r "$W/platform/targets/wasm32/host.wasm" "$EXTRA_OBJ" -o "$W/host-merged.wasm"
    cp "$W/host-merged.wasm" "$W/platform/targets/wasm32/host.wasm"
  fi
  O=$H/out/$v
  mkdir -p "$O/app"
  rsync -a --delete "$W/platform/" "$O/pf/"
  cp "$H/app/main.roc" "$O/app/main.roc"
  (cd "$O/app" && ROC_CACHE_DIR=$H/out/roccache XDG_CACHE_HOME=$H/out/xdg "$ROC" build --target=wasm32 --opt=speed --output=app.wasm main.roc)
  rsync -a --delete "$R/js/" "$O/app/.roc-cfw/"
  # The release host refuses resumeCheck "off" (research only, as ../app.sh).
  f=$O/app/.roc-cfw/index.js
  grep -q "runnerOpts.resumeCheck === 'off' && !isBenchHost(module)" "$f"
  sed -i "s/runnerOpts.resumeCheck === 'off' \&\& !isBenchHost(module)/false/" "$f"
  cat > "$O/app/worker.js" <<'W'
// research/alloc/foreign/heavy: the options come from CFW_TEST_OPTIONS (startApp).
import app from './app.wasm';
import { makeHandler } from './.roc-cfw/index.js';

export default makeHandler(app);
W
  cat > "$O/app/wrangler.toml" <<'T'
name = "heavy"
main = "worker.js"
compatibility_date = "2026-10-01"
compatibility_flags = ["enable_request_signal"]
T
  echo "built $v: $O/app ($(sha256sum "$O/app/app.wasm" | cut -c1-12))"
done
