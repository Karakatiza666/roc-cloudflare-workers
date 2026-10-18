#!/usr/bin/env bash
# Must-not-compile checks (MODULES.md 10, PLAN.md 8c): a `Secret` in the fields of a `Log` line, and in a CBOR encode.
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
exit "$rc"
