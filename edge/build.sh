#!/usr/bin/env bash
# PLAN.md 11c: builds the edge app on the bench platform. edge/gen-app.mjs writes edge/app.roc from conformance/app.roc
# (the conformance app and EdgeRoutes.roc). The script copies the route files of conformance/ into edge/ (ignored by
# git), so the app is one level below the root (roc refuses a platform path that goes up two directories, PLAN.md 8g
# GC1). Needs the bench host (`zig build -Dbench=true`, bench/build.sh).
#   ROC=<roc> edge/build.sh          gives .cache/edge/app.wasm
set -euo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
for f in conformance/*.roc; do
  [ "$(basename "$f")" = app.roc ] || cp "$f" edge/
done
node edge/gen-app.mjs
mkdir -p .cache/edge
"$ROC" build --opt=speed --target=wasm32 --no-cache --output=.cache/edge/app.wasm edge/app.roc || [ $? -eq 2 ]
ls -l .cache/edge/app.wasm
