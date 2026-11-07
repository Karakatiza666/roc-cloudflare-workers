#!/usr/bin/env bash
# The matrix for one variant: N tasks at once x live size, 180 s each (phases s, b, m of 60 s). Output: out/<v>-n<N>-kb<KB>.jsonl.
# Usage: heavy/run.sh <variant> [N list] [KB list]   (one run at a time per variant; variants can run side by side)
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
v=$1
for n in ${2:-2 5 10 20}; do
  for kb in ${3:-5120 10240 20480}; do
    echo "== $v n$n kb$kb $(date +%T)"
    node "$H/heavy.mjs" --app "$H/out/$v/app" --n $n --kb $kb --secs ${SECS:-180} --phases ${PHASES:-s,b,m} \
      --q "${Q:-waits=4&ms=250}" --out "$H/out/$v-n$n-kb$kb.jsonl" 2>&1 | tail -1
  done
done
