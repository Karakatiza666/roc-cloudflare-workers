#!/usr/bin/env bash
# Test that a platform bundle has the files of js/ (research/talon-fit/TRANSITION.md 4.1): `roc unbundle`, then a list.
# Usage: ROC=<roc> scripts/test_bundle_js.sh [bundle .tar.zst file]    (default: the file of dist/)
# Checks (each one fails the script):
#   1. Each file of js/ is in the unpacked bundle, and the unpacked js/ has no other file.
#   2. Each file but package.json has the content of the file in js/. package.json is `{ "type": "module" }` only.
#   3. js/cfw.json is `{ "api": 1 }`, and js/template/ has main.roc, wrangler.toml, talon.toml, .gitignore.
set -euo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
bundle=$(realpath "${1:-$(echo dist/*.tar.zst)}")
work=$PWD/.cache/test-bundle-js
rm -rf "$work"
mkdir -p "$work"
(cd "$work" && "$ROC" unbundle "$bundle" >&2)
dir=$(echo "$work"/*/)
test -d "$dir/js" || { echo "FAIL: the bundle has no js/ directory"; exit 1; }
want=$(find js -type f | LC_ALL=C sort)
got=$(cd "$dir" && find js -type f | LC_ALL=C sort)
if [ "$want" != "$got" ]; then echo "FAIL: the files of js/ and of the bundle differ"; diff <(echo "$want") <(echo "$got") || true; exit 1; fi
echo "files of js/ in the bundle: $(echo "$got" | wc -l)"
for f in $want; do
	[ "$f" = js/package.json ] && continue
	cmp -s "$f" "$dir/$f" || { echo "FAIL: $f differs from the bundle"; exit 1; }
done
[ "$(tr -d ' \n' < "$dir/js/package.json")" = '{"type":"module"}' ] || { echo "FAIL: js/package.json of the bundle is not only the type field"; exit 1; }
[ "$(tr -d ' \n' < "$dir/js/cfw.json")" = '{"api":1}' ] || { echo "FAIL: js/cfw.json is not { \"api\": 1 }"; exit 1; }
for f in main.roc wrangler.toml talon.toml .gitignore; do
	test -s "$dir/js/template/$f" || { echo "FAIL: js/template/$f is not in the bundle"; exit 1; }
done
echo "PASS test_bundle_js"
