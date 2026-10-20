#!/bin/sh
# Check and build the Gavel example with the 2 bad lines of REVIEW.md N2, then a cache case on a tiny platform.
# Usage: research/check-vs-build/run.sh <path to roc> [<path to roc> ...]. Run from the submodule root.
set -u
here=research/check-vs-build
g=$here/gavel
out=$here/out
mkdir -p "$out"
summary() { grep -E 'No errors found|errors? and [0-9]+ warnings|SIGSEGV|in the Roc compiler' | sed 's/─//g; s/^ *//' | head -1; }
put_bad() {
	sed -i 's#req.body(), { http#req.body, { http#' $g/web.roc
	sed -i 's#{ name: name })#{ name })#' $g/LotRoom.roc
}
put_good() {
	cp examples/auction/web.roc examples/auction/LotRoom.roc $g/
	sed -i 's#"../../platform/main.roc"#"../../../platform/main.roc"#' $g/web.roc
}
for roc in "$@"; do
	echo "== $("$roc" version)"
	rm -rf $g && mkdir -p $g && cp examples/auction/*.roc $g/
	sed -i 's#"../../platform/main.roc"#"../../../platform/main.roc"#' $g/web.roc $g/ledger.roc
	put_bad
	printf '%-40s %s\n' "gavel: check --no-cache web.roc" "$("$roc" check --no-cache $g/web.roc 2>&1 | summary)"
	printf '%-40s %s\n' "gavel: build --no-cache web.roc" "$("$roc" build --target=wasm32 --no-cache --output=$out/web.wasm $g/web.roc 2>&1 | summary)"
	printf '%-40s %s\n' "gavel: check --no-cache ledger.roc" "$("$roc" check --no-cache $g/ledger.roc 2>&1 | summary)"
	# Warm a fresh cache with the good files, then put the bad lines back and check with the cache.
	export ROC_CACHE_DIR=$PWD/$out/cache/roc XDG_CACHE_HOME=$PWD/$out/cache
	rm -rf $out/cache
	put_good
	printf '%-40s %s\n' "gavel: check good (warms cache)" "$("$roc" check $g/web.roc 2>&1 | summary)"
	put_bad
	printf '%-40s %s\n' "gavel: check bad, cached" "$("$roc" check $g/web.roc 2>&1 | summary)"
	# Tiny platform: the platform type changes from := to :: between two cached checks.
	rm -rf $out/cache
	cp $here/plat/Req_v1.roc $here/plat/Req.roc
	printf '%-40s %s\n' "tiny: check, Req := (warms cache)" "$("$roc" check $here/app.roc 2>&1 | summary)"
	cp $here/plat/Req_v2.roc $here/plat/Req.roc
	printf '%-40s %s\n' "tiny: check, Req :: cached" "$("$roc" check $here/app.roc 2>&1 | summary)"
	printf '%-40s %s\n' "tiny: check, Req :: --no-cache" "$("$roc" check --no-cache $here/app.roc 2>&1 | summary)"
	rm -f $here/plat/Req.roc
	unset ROC_CACHE_DIR XDG_CACHE_HOME
done
rm -rf $g $out
