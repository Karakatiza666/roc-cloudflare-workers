#!/usr/bin/env bash
# Compile matrix of option C (DbInt) against plain I64. Each case is Roc lines after a common header.
# want "-": must compile. Else: `roc check` must fail and print that text. Prints one line per case. Exit 1 on a mismatch.
# Run from any dir. Env: ROC (default: bench/get-roc.sh of this repo).
set -uo pipefail
cd "$(dirname "$0")/../.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
tmp=research/d1-int-helper/roc/_case.roc
trap 'rm -f "$tmp"' EXIT
rc=0
header='app [event!] { pf: platform "../../../platform/main.roc" }
import pf.Worker
import pf.Cbor
import DbInt
worker = Worker.new({ fetch!: |_req| crash "unused" })
event! = |e| worker.event!(e)
x : DbInt
x = 41
n : I64
n = 41'
cases=(
  'C x + 1|y = x + 1|-'
  'C x - 1, x * 2, x // 2, x % 2, -x|y = [x - 1, x * 2, x // 2, x % 2, -x]|-'
  'C x == 5, x != 5|y = x == 5 and x != 5|-'
  'C x > 0, 0 < x, x >= 0, 0 <= x|y = x > 0 and 0 < x and x >= 0 and 0 <= x|-'
  'C 5 == x|y = 5 == x|-'
  'C 1 + x (literal on the left)|y = 1 + x|MISSING METHOD'
  'C 1 + x, the result annotated|y : DbInt\ny = 1 + x|-'
  'C 2 * x + 1 (literal on the left)|y = 2 * x + 1|MISSING METHOD'
  'C a literal suffix 7.DbInt|y = 7.DbInt + x|-'
  'C x + n (I64)|y = x + n|TYPE MISMATCH'
  'C x == n (I64)|y = x == n|TYPE MISMATCH'
  'C x.to_i64() + n|y = x.to_i64() + n|-'
  'C x.abs() (no wrapper)|y = x.abs()|MISSING METHOD'
  'C x.plus_try(1) (no wrapper)|y = x.plus_try(1)|MISSING METHOD'
  'C x..<x (range)|y = x..<x|MISSING METHOD'
  'C a too big literal|y : DbInt\ny = 9223372036854775808|invalid number'
  'C x in CBOR (SQL parameter)|y = Cbor.encode([x])|-'
  'C x in JSON|y = Encoding.Json.to_str({ id: x })|-'
  'C x.to_str()|y = x.to_str()|-'
  'A I64: 1 + n, 2 * n + 1|y = 1 + n + 2 * n|-'
  'A I64: n + 1, 0 < n, 5 == n|y = n + 1 > 0 and 0 < n and 5 == n|-'
)
for c in "${cases[@]}"; do
  IFS='|' read -r name line want <<< "$c"
  printf '%s\n%b\n' "$header" "$line" > "$tmp"
  out=$("$ROC" check "$tmp" 2>&1); code=$?
  if [ "$want" = "-" ]; then
    if [ $code -eq 0 ]; then echo "ok   compiles      | $name"; else echo "BAD  should compile | $name"; echo "$out" | grep -A8 '──' | head -12; rc=1; fi
  else
    if [ $code -ne 0 ] && grep -qi "$want" <<< "$out"; then echo "ok   fails ($want) | $name"; else echo "BAD  want $want, code $code | $name"; echo "$out" | grep -A8 '──' | head -12; rc=1; fi
  fi
done
exit $rc
