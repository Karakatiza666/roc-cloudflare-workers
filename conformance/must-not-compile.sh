#!/usr/bin/env bash
# Must-not-compile checks (MODULES.md 10, PLAN.md 8c): a `Secret` in the fields of a `Log` line, and in a CBOR encode.
# PLAN.md 8h: an Rpc handler with a tag that is not in `err`, a `Worker.new` field of the wrong handler type, and the
# files that must compile (one error type for each handler).
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
exit "$rc"
