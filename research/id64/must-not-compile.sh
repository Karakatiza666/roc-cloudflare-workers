#!/usr/bin/env bash
# Must-not-compile checks of Id64. Each case is one line of Roc after a common header.
# A bad case must fail `roc check` with the expected text in the error. The control must pass,
# so the failure is the line and not the header. Run from any dir. Env: ROC (default: bench/get-roc.sh). Exit 1 on a failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
tmp=research/id64/_case.roc
trap 'rm -f "$tmp"' EXIT
rc=0
header='app [event!] { pf: platform "../../platform/main.roc" }
import pf.Worker
import pf.Cbor
import Id64
worker = Worker.{ fetch!: |_req| crash "unused" }
event! = |e| worker.event!(e)
id = Id64.from_u64(5)'
# case name | line | expected error text ("-" for the control, which must compile)
cases=(
  'control: to_u64 math is allowed|x = id.to_u64() + 1|-'
  'control: Id64.Web in JSON|x = Encoding.Json.to_str({ id: id.to_web() })|-'
  'control: Id64 in CBOR|x = Cbor.encode({ id })|-'
  'id + 1|x = id + 1|MISSING METHOD'
  'id + id|x = id + id|MISSING METHOD'
  'id.plus(1)|x = id.plus(1)|MISSING METHOD'
  'id < id (no order)|x = id < id|MISSING METHOD'
  'id.bits (hidden field)|x = id.bits|TYPE MISMATCH'
  'literal as Id64|x : Id64\nx = 5|TYPE MISMATCH'
  'U64 compared to Id64|x = id.to_u64() + 1 == id|TYPE MISMATCH'
  'record literal as Id64|x : Id64\nx = { bits: 5 }|TYPE MISMATCH'
  'Id64 in JSON (write)|x = Encoding.Json.to_str({ id })|encode_bytes'
  'Id64 in JSON (write), bare|x = Encoding.Json.to_str(id)|encode_bytes'
  'Id64.{ bits }|x = Id64.{ bits: 5 }|opaque'
)
for c in "${cases[@]}"; do
  IFS='|' read -r name line want <<< "$c"
  printf '%s\n%b\n' "$header" "$line" > "$tmp"
  out=$("$ROC" check "$tmp" 2>&1); code=$?
  if [ "$want" = "-" ]; then
    if [ $code -eq 0 ]; then echo "PASS $name"; else echo "FAIL $name: the control does not compile"; echo "$out" | head -12; rc=1; fi
  elif [ $code -eq 1 ] && grep -qi "$want" <<< "$out"; then echo "PASS $name does not compile ($want)"
  else echo "FAIL $name: it compiles, or the error has no '$want'"; echo "$out" | head -12; rc=1; fi
done
exit "$rc"
