#!/usr/bin/env bash
# Run the probes of research/d1-int-helper: the Roc tests, the compile matrix, and the JS probe of local D1.
# Env: PF_ROOT, the platform root to test against (default: this repo). When it is another tree (a worktree), the
# probes are copied to $PF_ROOT/research/d1-int-helper/, so the relative platform path holds.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
root=${PF_ROOT:-$repo}
if [ "$root" != "$repo" ]; then mkdir -p "$root/research/d1-int-helper"; cp -r "$here/roc" "$here/must-not-compile.sh" "$root/research/d1-int-helper/"; fi
cd "$root"
export ROC=${ROC:-$(cd "$repo" && bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
rc=0
"$ROC" test research/d1-int-helper/roc/app.roc || rc=1
"$ROC" test research/d1-int-helper/roc/SqlInt.roc || rc=1
"$ROC" check research/d1-int-helper/roc/usage.roc || rc=1
research/d1-int-helper/must-not-compile.sh || rc=1
node "$here/js/exact.mjs" > /dev/null || rc=1
exit $rc
