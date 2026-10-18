#!/usr/bin/env bash
# Must-not-compile checks (MODULES.md 10, PLAN.md 8c): a `Secret` in the fields of a `Log` line, and in a CBOR encode. Also `Id64` (MODULES.md 5.1).
# PLAN.md 8h: an Rpc handler with a tag that is not in `err`, a `Worker.new` field of the wrong handler type, and the
# files that must compile (one error type for each handler). SQL parameters (MODULES.md 5.1).
# Each `*_bad.roc` must fail `roc check` with an error that names `Secret`, and its `*_ok.roc` (the same file with
# `s.reveal()`) must pass, so the error is the secret and not another fault. The CBOR files import `pf.Cbor` (the platform module that
# wraps `roc-cbor`, MC5) and have no `cbor` entry. Env: ROC (default: bench/get-roc.sh). Exit 1 on a failure.
set -uo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
dir=conformance/must-not-compile
rc=0
for kind in log cbor; do
  out=$("$ROC" check "$dir/secret_${kind}_bad.roc" 2>&1)
  if [ $? -eq 1 ] && grep -q 'Secret' <<< "$out"; then echo "PASS secret_${kind}_bad.roc does not compile (an error names Secret)"
  else echo "FAIL secret_${kind}_bad.roc: it compiles, or the error does not name Secret"; echo "$out" | head -20; rc=1; fi
  out=$("$ROC" check "$dir/secret_${kind}_ok.roc" 2>&1)
  if [ $? -eq 0 ]; then echo "PASS secret_${kind}_ok.roc compiles"
  else echo "FAIL secret_${kind}_ok.roc: the control does not compile"; echo "$out" | head -20; rc=1; fi
done

# Id64 (MODULES.md 5.1, "Ids: Id64"): one line of Roc after a header. A bad case must fail `roc check` with the expected text in the
# error. The controls must pass, so the failure is the line and not the header.
tmp=$dir/_id64_case.roc
trap 'rm -f "$tmp"' EXIT
header='app [event!] { pf: platform "../../bench/platform/main.roc" }
import pf.Worker
import pf.Cbor
import pf.Id64
import pf.Sql
worker = Worker.new({ fetch!: |_req| crash "unused" })
event! = |e| worker.event!(e)
id = Id64.from_u64(5)'
# name | line | expected error text ("-" for a control, which must compile)
cases=(
  'control: to_u64 math is allowed|x = id.to_u64() + 1|-'
  'control: Id64.Web in JSON (write)|x = Encoding.Json.to_str({ id: id.to_web() })|-'
  'control: Id64.Web in JSON (read)|x : Try({ id : Id64.Web }, _)\nx = Encoding.Json.parse("{}")|-'
  'control: Id64 in CBOR (write)|x = Cbor.encode({ id })|-'
  'control: Id64 in CBOR (read)|x : Try({ id : Id64 }, _)\nx = Cbor.parse([])|-'
  'control: Id64 in a SQL parameter tuple|x = Sql.stmt("SELECT ?, ?", (id, 1.I64))|-'
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
  'Id64 in JSON (read)|x : Try({ id : Id64 }, _)\nx = Encoding.Json.parse("{}")|parse_bytes'
  'Id64.{ bits }|x = Id64.{ bits: 5 }|opaque'
)
for c in "${cases[@]}"; do
  IFS='|' read -r name line want <<< "$c"
  printf '%s\n%b\n' "$header" "$line" > "$tmp"
  out=$("$ROC" check "$tmp" 2>&1); code=$?
  if [ "$want" = "-" ]; then
    if [ $code -eq 0 ]; then echo "PASS Id64 $name"; else echo "FAIL Id64 $name: the control does not compile"; echo "$out" | head -12; rc=1; fi
  elif [ $code -eq 1 ] && grep -qi "$want" <<< "$out"; then echo "PASS Id64 $name does not compile ($want)"
  else echo "FAIL Id64 $name: it compiles, or the error has no '$want'"; echo "$out" | head -12; rc=1; fi
done
# A control only: a record with an `F64` field is JSON-encodable (the open error of `Json.Encodable(enc)`).
out=$("$ROC" check "$dir/f64_json_ok.roc" 2>&1)
if [ $? -eq 0 ]; then echo "PASS f64_json_ok.roc compiles"
else echo "FAIL f64_json_ok.roc: a record with an F64 field does not compile as JSON"; echo "$out" | head -20; rc=1; fi
# PLAN.md 8h item 3: SQL parameters. A U128 parameter fails with a missing `encode_u128`, a bare `[]` with "type not determined"
# for `encoder_for`. Each `_ok` file is the same call with an allowed type (a U64, `Sql.none`).
for pair in 'u128:encode_u128' 'empty:encoder_for'; do
  kind=${pair%%:*}; word=${pair#*:}
  out=$("$ROC" check "$dir/sql_${kind}_bad.roc" 2>&1)
  if [ $? -eq 1 ] && grep -q "$word" <<< "$out"; then echo "PASS sql_${kind}_bad.roc does not compile (an error names $word)"
  else echo "FAIL sql_${kind}_bad.roc: it compiles, or the error does not name $word"; echo "$out" | head -20; rc=1; fi
  out=$("$ROC" check "$dir/sql_${kind}_ok.roc" 2>&1)
  if [ $? -eq 0 ]; then echo "PASS sql_${kind}_ok.roc compiles"
  else echo "FAIL sql_${kind}_ok.roc: the control does not compile"; echo "$out" | head -20; rc=1; fi
done
# 8h: a `set!` of a typed socket attachment with a value of another type (attachment_bad.roc).
# 8h: `<name>_bad.roc` must fail with an error that has the text `want`; `control` must compile.
pair() {
  local bad=$1 want=$2 control=$3
  out=$("$ROC" check "$dir/$bad" 2>&1)
  if [ $? -eq 1 ] && grep -qF -- "$want" <<< "$out"; then echo "PASS $bad does not compile (an error has \"$want\")"
  else echo "FAIL $bad: it compiles, or the error does not have \"$want\""; echo "$out" | head -20; rc=1; fi
  out=$("$ROC" check "$dir/$control" 2>&1)
  if [ $? -eq 0 ]; then echo "PASS $control compiles"
  else echo "FAIL $control: the control does not compile"; echo "$out" | head -20; rc=1; fi
}
pair rpc_tag_bad.roc 'Err([Busy])' rpc_tag_ok.roc
pair worker_field_bad.roc 'fetch! ?: Str => Try(Response, [])' worker_errs_ok.roc
pair attachment_bad.roc 'slot.set!(socket, { name: 5 })' attachment_ok.roc
exit "$rc"
