#!/usr/bin/env bash
# Base (before) against alloc_spans (the size class change of hostlib/alloc.zig, 2026-11-08). Usage: heavy/spans.sh <set>
#   pair: base and alloc_spans side by side: `b` N=16, `l` N=16 (120 s), s,b,m N=10 (180 s). Base files get the tag -re.
#   fit:  alloc_spans only, near the limit: `b` N=20, 24; `l` N=20, 24; s,b,m N=16 (120 s).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
r() { # variant n secs phases tag
  echo "== $1 n$2 $4$5 $(date +%T)"
  node "$H/heavy.mjs" --app "$H/out/$1/app" --n $2 --kb 5120 --secs $3 --phases $4 --q "waits=4&ms=250" --out "$H/out/$1-n$2-kb5120$5.jsonl" 2>&1 | tail -n 1
}
case $1 in
  pair)
    for v in base alloc_spans; do
      t=""; [ $v = base ] && t=-re
      ( r $v 16 120 b "-b$t"; r $v 16 120 l "-l$t"; r $v 10 180 s,b,m "$t" ) &
    done
    wait ;;
  fit)
    ( r alloc_spans 20 120 b -b; r alloc_spans 24 120 b -b ) &
    ( r alloc_spans 20 120 l -l; r alloc_spans 24 120 l -l ) &
    wait
    r alloc_spans 16 120 s,b,m "" ;;
esac
