#!/usr/bin/env bash
# Test a release (PLAN.md 11a, 11b): build the examples against the bundle, run one in wrangler with the js/ of the bundle.
# Usage: ROC=<roc> scripts/test_bundle.sh [bundle .tar.zst file or https URL]
# Default: the file of dist/ (made by scripts/bundle.sh). A file is served on http://127.0.0.1 (Roc allows plain
# http only for localhost). `--replace-dep OLD NEW` changes no file: OLD is the platform path of the examples, from here.
# Steps (each one fails the script):
#   1. `roc check` and `roc build` of examples/hello/main.roc and examples/hello/with_cbor.roc against the bundle,
#      with an empty package cache (XDG_CACHE_HOME) so that http and cbor come from their URLs.
#   1b. scripts/test_bundle_js.sh: the bundle has the files of js/ (a URL is downloaded first).
#   2. scripts/test_example.sh: the app of 1 in `wrangler dev --local` with the js/ of the bundle (the unpacked bundle in
#      the package cache of step 1: $XDG_CACHE_HOME/roc/packages/<hash>/js/), then `wrangler deploy --dry-run`.
set -euo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
bundle=${1:-$(echo dist/*.tar.zst)}
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

for app in hello with_cbor; do
	src=examples/hello/$app.roc
	[ "$app" = hello ] && src=examples/hello/main.roc
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
# roc unbundle reads the hash from the file name, so the download keeps the name of the asset.
if [[ $bundle == https://* ]]; then name=${bundle##*/}; curl -fsSL -o "$work/$name" "$bundle"; scripts/test_bundle_js.sh "$work/$name"; else scripts/test_bundle_js.sh "$bundle"; fi
# The js/ of the unpacked bundle in the package cache: the shim that a user gets with the platform.
bundle_js=$XDG_CACHE_HOME/roc/packages/$(basename "$url" .tar.zst)/js
test -f "$bundle_js/cli.mjs" || { echo "FAIL: $bundle_js/cli.mjs is not in the package cache"; exit 1; }
scripts/test_example.sh "$work/hello.wasm" "$bundle_js"
echo "PASS test_bundle"
