#!/bin/sh
# Run each probe of README.md. Run from the submodule root: research/n5-rpc-errors/run.sh
# OPT=size research/n5-rpc-errors/run.sh builds with --opt=size. Each line gives the file and the first line of the
# result. The wasm files go to a temp dir, and the last lines give their sizes.
set -u
ROC=$(bench/get-roc.sh)
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
D=research/n5-rpc-errors
OUT=$(mktemp -d)
OPTFLAG=""
[ -n "${OPT:-}" ] && OPTFLAG="--opt=$OPT"
first() { grep -E "errors? and|^Err|^Ok|^not open|^\{|^404|passed|failed|crash" | head -1; }
for f in q1_extend q2_fault q6_widen q7_wrap_infra q8_nested q9_forward_g q10_row_infra; do
	printf '%-30s %s\n' "$f (run)" "$(timeout 600 "$ROC" --no-cache "$D/$f.roc" 2>&1 | first)"
done
for f in q3_narrow q4_codec q5_empty_row q6_widen_fail q10_fail; do
	printf '%-30s %s\n' "$f (check, error)" "$(timeout 600 "$ROC" check --no-cache "$D/$f.roc" 2>&1 | grep -E '✗' | head -1)"
done
# The platform copies of option G (G1a) and of its control G0 (the same wrappers, flat errors).
"$D/make-platform-g.sh" > /dev/null
build() {
	printf '%-30s %s\n' "$1 (build)" "$(timeout 600 "$ROC" build $OPTFLAG --target=wasm32 --no-cache --output="$OUT/$(echo $1 | tr / -).wasm" "$2" 2>&1 | first)"
}
for a in web ledger; do
	build "base/$a" "examples/auction/$a.roc"
	for v in option-c option-e option-g option-g0 option-b; do build "$v/$a" "$D/$v/$a.roc"; done
done
printf '%-30s %s\n' "option-c (test)" "$(timeout 600 "$ROC" test --no-cache "$D/option-c/web.roc" 2>&1 | first)"
ls -l "$OUT" | awk 'NR > 1 { print $5, $9 }'
