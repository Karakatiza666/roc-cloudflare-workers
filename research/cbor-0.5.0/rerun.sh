#!/usr/bin/env bash
# The CBOR-related checks of bench/test-all.sh, and the conformance app in --opt=size and --opt=dev.
# Env as bench/test-all.sh (ZIG, WORKERD, ROC). One line for each step: the exit code and the name.
set -uo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .cache/out-modes
rc=0
step() {
  local name=$1; shift
  timeout "${STEP_TIMEOUT:-1800}" "$@" > ".cache/rerun-step.log" 2>&1
  local code=$?
  printf '%3d  %s\n' "$code" "$name"
  if [ "$code" -ne 0 ]; then rc=1; { grep -E '^FAIL ' .cache/rerun-step.log | head -n 20; tail -n 8 .cache/rerun-step.log; } | cut -c1-300 | sed 's/^/     | /'; fi
}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
step "roc check platform/main.roc" "$ROC" check platform/main.roc
step "roc test platform/main.roc" "$ROC" test platform/main.roc
step "roc test research/cbor-0.5.0/wire.roc" "$ROC" test research/cbor-0.5.0/wire.roc
step "build (bench/build.sh, --opt=speed)" bench/build.sh
step "exports-test.mjs" node bench/exports-test.mjs bench/out/app_prod.wasm bench/out/app.wasm
step "node-test.mjs" node bench/node-test.mjs bench/out/app.wasm
step "cbor-js-test.mjs" node bench/cbor-js-test.mjs
step "cbor-wasm-test.mjs" node bench/cbor-wasm-test.mjs bench/out/app.wasm
step "hd4-test.mjs" node bench/hd4-test.mjs bench/out/app.wasm
step "bridge-test.mjs" node bench/bridge-test.mjs bench/out/app_bridge.wasm
step "bridge-workerd.mjs" node bench/bridge-workerd.mjs
step "entry-test.mjs" node bench/entry-test.mjs bench/out/app_events.wasm
step "trap-test.mjs" node bench/trap-test.mjs bench/out
step "conformance/run.mjs (speed)" node conformance/run.mjs bench/out/conformance.wasm
step "conformance/must-not-compile.sh" conformance/must-not-compile.sh
step "memo-roundtrip/dev-check.sh (dev)" research/memo-roundtrip/dev-check.sh
step "build conformance --opt=size" "$ROC" build --opt=size --target=wasm32 --no-cache --output=.cache/out-modes/conformance-size.wasm conformance/app.roc
step "conformance/run.mjs (size)" node conformance/run.mjs .cache/out-modes/conformance-size.wasm
step "conformance/run.mjs (dev, all checks)" node conformance/run.mjs bench/out/conformance-dev.wasm
th=.cache/test-helper
mkdir -p "$th"
step "build examples/hello, with_cbor and test-helper/app (production host)" bash -c 'cd examples/hello && "$0" build --target=wasm32 --no-cache --output="$1" main.roc && "$0" build --target=wasm32 --no-cache --output="$3" with_cbor.roc && cd ../../test-helper/app && "$0" build --target=wasm32 --no-cache --output="$2" main.roc' "$ROC" "$PWD/$th/hello.wasm" "$PWD/$th/helper.wasm" "$PWD/$th/with_cbor.wasm"
step "test-helper/helper-test.mjs" node test-helper/helper-test.mjs "$th/hello.wasm" "$th/helper.wasm"
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "FAIL"
exit "$rc"
