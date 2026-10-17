#!/usr/bin/env bash
# Test a release (PLAN.md 11a, 11b): build the examples against the bundle, run one in wrangler with the shim package.
# Usage: ROC=<roc> scripts/test_bundle.sh [bundle .tar.zst file or https URL] [shim .tgz file or URL]
# Defaults: the files of dist/ (made by scripts/bundle.sh). A file is served on http://127.0.0.1 (Roc allows plain
# http only for localhost). `--replace-dep OLD NEW` changes no file: OLD is the platform path of the examples, from here.
# Steps (each one fails the script):
#   1. `roc check` and `roc build` of examples/hello/app.roc and examples/hello/with_cbor.roc against the bundle,
#      with an empty package cache (XDG_CACHE_HOME) so that http and cbor come from their URLs.
#   2. scripts/test_example.sh: the app of 1 in `wrangler dev --local` with the shim package, then `wrangler deploy --dry-run`.
set -euo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
bundle=${1:-$(echo dist/*.tar.zst)}
shim=${2:-$(echo dist/*.tgz)}
work=$PWD/.cache/test-bundle
export TMPDIR=${TMPDIR:-$PWD/.cache/tmp}
mkdir -p "$TMPDIR"
rm -rf "$work"
mkdir -p "$work"
# Empty caches: the packages of the platform header download again. ROC_CACHE_DIR: the build cache.
export ROC_CACHE_DIR=$work/roc-cache XDG_CACHE_HOME=$work/xdg-cache

if [[ $bundle == https://* ]]; then
	url=$bundle
else
	port=${PORT:-8765}
	url="http://127.0.0.1:$port/$(basename "$bundle")"
	setsid bash -c 'echo $$ > "$0"; exec python3 -m http.server "$1" --bind 127.0.0.1 --directory "$2"' "$work/server.pid" "$port" "$(dirname "$bundle")" > /dev/null 2>&1 &
	trap 'kill -- -"$(cat "$work/server.pid")" 2>/dev/null || true' EXIT
	for _ in $(seq 50); do
		(: > "/dev/tcp/127.0.0.1/$port") 2> /dev/null && break
		sleep 0.1
	done
fi
echo "bundle: $url"
echo "shim: $shim"

for app in hello with_cbor; do
	src=examples/hello/$app.roc
	[ "$app" = hello ] && src=examples/hello/app.roc
	"$ROC" check "$src" --replace-dep ./platform/main.roc "$url"
	# `--no-cache`: a warm build cache gave other code (PLAN.md, status of 11a).
	"$ROC" build --opt=speed --target=wasm32 --no-cache --output="$work/$app.wasm" "$src" --replace-dep ./platform/main.roc "$url"
	node bench/check-layout.mjs --header platform/main.roc "$work/$app.wasm"
done
# The cache has the bundle and the two header packages (http, cbor): each from its URL, none from a path.
hashes=$(basename "$url" .tar.zst; grep -o '[1-9A-HJ-NP-Za-km-z]\{43,44\}\.tar\.zst' platform/main.roc | sed 's/\.tar\.zst//')
test "$(echo "$hashes" | wc -l)" = 3
for h in $hashes; do
	[ -d "$XDG_CACHE_HOME/roc/packages/$h" ] || { echo "FAIL: $h is not in the package cache"; exit 1; }
done
echo "packages in the cache: $(echo $hashes)"
scripts/test_example.sh "$work/hello.wasm" "$shim"
echo "PASS test_bundle"
