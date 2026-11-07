#!/usr/bin/env bash
# Runs after the matrix (run.sh). Usage: heavy/extra.sh <variant> <set>
#   fit:  more N x KB pairs near the limit, 120 s, phases s,b,m. Output out/<v>-n<N>-kb<KB>.jsonl
#   keep2: N=10, 5 MB, keep 1 of 2 after the hold (each page stays half full until the task ends). out/<v>-n10-kb5120-keep2.jsonl
#   bs:   N=10, 5 MB, phases b then s (small after big). out/<v>-n10-kb5120-bs.jsonl
#   bonly: only big strings (200..1999 B), N=10, 16, 20, 5 MB, 120 s. out/<v>-n<N>-kb5120-b.jsonl
#   lonly: only large strings (2100..8099 B), N=10, 16, 5 MB, 120 s. out/<v>-n<N>-kb5120-l.jsonl
#   long: N=10, 5 MB, 600 s, phases s,b,m,s,b,m. out/<v>-n10-kb5120-long.jsonl
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
v=$1
r() { # n kb secs phases q tag
  echo "== $v n$1 kb$2 $6 $(date +%T)"
  node "$H/heavy.mjs" --app "$H/out/$v/app" --n $1 --kb $2 --secs $3 --phases $4 --q "$5" --out "$H/out/$v-n$1-kb$2$6.jsonl" 2>&1 | tail -n 1
}
case $2 in
  fit)
    if [ "$v" = fa_zig ]; then pairs="6:5120 7:5120 8:5120 3:10240 4:10240 1:20480"
    else pairs="12:5120 14:5120 16:5120 6:10240 7:10240 8:10240 3:20480 4:20480"; fi
    for p in $pairs; do r ${p%%:*} ${p##*:} 120 s,b,m "waits=4&ms=250" ""; done ;;
  keep2) r 10 5120 120 s,b,m "waits=4&ms=250&keep=2" -keep2 ;;
  bs) r 10 5120 120 b,s "waits=4&ms=250" -bs ;;
  bonly) for n in 10 16 20; do r $n 5120 120 b "waits=4&ms=250" -b; done ;;
  lonly) for n in 10 16; do r $n 5120 120 l "waits=4&ms=250" -l; done ;;
  long) r 10 5120 600 s,b,m,s,b,m "waits=4&ms=250" -long ;;
esac
