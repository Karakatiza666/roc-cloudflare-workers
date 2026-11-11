#!/usr/bin/env bash
# The memo checks of the conformance app, built with --opt=dev (the build mode of the Talon W2 harness).
# Usage: research/memo-roundtrip/dev-check.sh. Env: ROC (default: the nightly of compat/last-stack-first-nightly),
# ROC_CBOR: a roc-cbor src/main.roc to use in place of the 0.2.3 release URL (for example a local checkout).
# Needs the bench host (bench/build.sh, or build-conf.sh here). Exit 1 when a memo check fails.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
url=https://github.com/Karakatiza666/roc-cbor/releases/download/0.2.3/GkHriTGSE8ww1h2HvUL3GS6x1t2keTW13KQazoUZh4Uc.tar.zst
dep=()
[ -n "${ROC_CBOR:-}" ] && dep=(--replace-dep "$url" "$ROC_CBOR")
mkdir -p bench/out
"$ROC" build --opt=dev --target=wasm32 --no-cache --wasm-stack-size="$(cat compat/dev-stack-size)" "${dep[@]}" --output=bench/out/conformance-dev.wasm conformance/app.roc || [ $? -eq 2 ]
# "memo " with the space: not the checks with "memory" in the name.
node conformance/run.mjs bench/out/conformance-dev.wasm "memo "
