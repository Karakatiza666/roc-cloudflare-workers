#!/usr/bin/env bash
# Build the registry copy on a variant host: research/alloc/variant-platform.sh into <reg>/pfv, then a Roc build of <reg>/wv
# (its main.roc names ../pfv/main.roc) with the Roc cache on, so only the parts that see the host are built again (about
# 2.5 min, not 5). Output: <reg>/w2-<name>/app.wasm and .roc-cfw/ (a W2_DIR for research/regprof/cpuseries.mjs).
# Usage: ZIG=<zig 0.17> REG=<reg dir> research/alloc/variant-app.sh <alloc.zig> <name>
set -euo pipefail
A=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$A/../.." && pwd)
"$A/variant-platform.sh" "$1" "$REG/pfv"
cd "$REG/wv"
ROC_CACHE_DIR=${ROC_CACHE_DIR:-$REG/../roccache} XDG_CACHE_HOME=${XDG_CACHE_HOME:-$REG/../xdg} \
  "$R/.cache/nightlies/nightly-2026-10-31-f7bef6b/roc" build --target=wasm32 --opt=speed --output=app.wasm main.roc
mkdir -p "$REG/w2-$2"
cp app.wasm "$REG/w2-$2/"
rsync -a --delete "$REG/wv/.roc-cfw/" "$REG/w2-$2/.roc-cfw/"
echo "built $REG/w2-$2"
