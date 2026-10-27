#!/usr/bin/env bash
# Design issue 9: can `Js` import `Io`, so that `Io.new` and `Io.sync` move under `Js`? Copies platform/ to a temp dir in
# .cache, applies js-imports-io.patch (Js imports Io and wraps Io.new) and runs `roc check`. Expect "import cycle detected".
set -uo pipefail
cd "$(dirname "$0")/../../.."
roc=.cache/nightlies/$(cat compat/last-stack-first-nightly)/roc
dir=.cache/i9-io-cycle
rm -rf "$dir" && mkdir -p "$dir" && cp -r platform "$dir/"
patch -s -d "$dir" -p0 < research/doc-fixes/i9_io_cycle/js-imports-io.patch
"$roc" check --no-cache "$dir/platform/main.roc" 2>&1 | grep -A3 "import cycle detected"
