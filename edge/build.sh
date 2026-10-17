#!/usr/bin/env bash
# PLAN.md 11c: builds the edge app (edge/app.roc: the conformance app and EdgeRoutes.roc) on the bench platform.
# It copies the route files of conformance/ into edge/ (ignored by git), so the app is one level below the root
# (roc refuses a platform path that goes up two directories, PLAN.md 8g GC1). Needs the bench host (bench/build.sh).
#   ROC=<roc> edge/build.sh          gives .cache/edge/app.wasm
set -euo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
for f in conformance/*.roc; do
  [ "$(basename "$f")" = app.roc ] || cp "$f" edge/
done
# The queue names of the edge run have the prefix (edge/deploy.sh).
sed -i 's/"jobs" =>/"rocplat-test-jobs" =>/; s/"texts" =>/"rocplat-test-texts" =>/; s/"bin" =>/"rocplat-test-bin" =>/' edge/QueueRoutes.roc
mkdir -p .cache/edge
"$ROC" build --opt=speed --target=wasm32 --no-cache --output=.cache/edge/app.wasm edge/app.roc || [ $? -eq 2 ]
ls -l .cache/edge/app.wasm
