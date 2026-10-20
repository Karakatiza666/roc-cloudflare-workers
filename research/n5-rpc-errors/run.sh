#!/bin/sh
# Run each probe of README.md. Run from the submodule root: research/n5-rpc-errors/run.sh
# Each line gives the file and the first line of the result. The wasm files go to a temp dir.
set -u
ROC=$(bench/get-roc.sh)
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
D=research/n5-rpc-errors
OUT=$(mktemp -d)
first() { grep -E "errors? and|^Err|^Ok|^not open|^\{|passed|failed|crash" | head -1; }
for f in q1_extend q2_fault q6_widen q7_wrap_infra; do
	printf '%-28s %s\n' "$f (run)" "$(timeout 600 "$ROC" --no-cache "$D/$f.roc" 2>&1 | first)"
done
for f in q3_narrow q4_codec q5_empty_row q6_widen_fail; do
	printf '%-28s %s\n' "$f (check, error)" "$(timeout 600 "$ROC" check --no-cache "$D/$f.roc" 2>&1 | grep -E '✗' | head -1)"
done
for a in option-b/web option-b/ledger option-c/web option-c/ledger; do
	printf '%-28s %s\n' "$a (build)" "$(timeout 600 "$ROC" build --target=wasm32 --no-cache --output="$OUT/$(echo $a | tr / -).wasm" "$D/$a.roc" 2>&1 | first)"
done
printf '%-28s %s\n' "option-c (test)" "$(timeout 600 "$ROC" test --no-cache "$D/option-c/web.roc" 2>&1 | first)"
ls -l "$OUT"
