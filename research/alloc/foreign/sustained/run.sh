#!/usr/bin/env bash
# All runs, one after the other (the server port and state/ are shared). Output: out/<scenario>-<variant>-c<c>.jsonl
# V="<variants>" (dirs in ../edge) picks the variants (default: base fa_dl fa_zig).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$D/out"
for sc in "mixed:60000" "closure,releases:40000"; do
  for c in 10 32; do
    for v in ${V:-base fa_dl fa_zig}; do
      name=${sc%%:*}; name=${name//,/+}
      echo "== $name $v c$c"
      node "$D/sustained.mjs" --edge "$D/../edge/$v" --mix "${sc%%:*}" --n "${sc##*:}" --c $c --out "$D/out/$name-$v-c$c.jsonl"
    done
  done
done
