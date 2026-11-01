#!/usr/bin/env bash
# Build the conformance app (bench platform) and bench/app_prod.roc (production platform) with an older nightly,
# against the hosts that bench/build.sh made with the pinned nightly (the glue is not made again), then run the tests
# that take a wasm file. Usage: research/min-nightly/try.sh <nightly tag>. Output: .cache/min-nightly/<tag>/.
set -uo pipefail
cd "$(dirname "$0")/../.."
tag=$1
ROC=$(bench/get-roc.sh "$tag")
out=.cache/min-nightly/$tag
mkdir -p "$out"
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
for app in conformance/app.roc bench/app_prod.roc bench/app.roc bench/app_b3.roc; do
  name=$(basename "$app" .roc); [ "$name" = app ] && [ "$app" = conformance/app.roc ] && name=conformance
  "$ROC" build --opt=speed --target=wasm32 --no-cache --output="$out/$name.wasm" "$app" > "$out/$name.build.log" 2>&1
  echo "build $name: exit $? ($(tail -n 3 "$out/$name.build.log" | grep -o '[0-9]* errors and [0-9]* warnings' | head -1))"
done
node bench/check-layout.mjs --header platform/main.roc "$out/app.wasm" "$out/app_prod.wasm" 2>&1 | tail -n 2
node -e 'const fs=require("fs");for (const f of process.argv.slice(1)) { try { const n=WebAssembly.Module.exports(new WebAssembly.Module(fs.readFileSync(f))).map(e=>e.name); console.log(f, "stack exports:", ["__stack_pointer","__stack_low","__stack_high"].filter(x=>n.includes(x)).join(" ")||"none") } catch(e) { console.log(f, e.message) } }' "$out/app_prod.wasm" "$out/conformance.wasm"
node bench/node-test.mjs "$out/app.wasm" > "$out/node-test.log" 2>&1; echo "node-test: exit $?"
node bench/handler-test.mjs "$out/app.wasm" "$out/app_prod.wasm" > "$out/handler-test.log" 2>&1; echo "handler-test: exit $?"
node bench/exports-test.mjs "$out/app_prod.wasm" "$out/app.wasm" > "$out/exports-test.log" 2>&1; echo "exports-test: exit $? ($(grep -c ^FAIL "$out/exports-test.log") FAIL lines)"
node conformance/run.mjs "$out/conformance.wasm" > "$out/conformance.log" 2>&1; echo "conformance: exit $? ($(tail -n 1 "$out/conformance.log"))"
