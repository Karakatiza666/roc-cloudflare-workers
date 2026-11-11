#!/usr/bin/env bash
# The stack size of each build mode (README.md, "Stack size"). A speed or size build has the stack of the platform header
# (`initial_stack_size: 1048576`, 1 MiB). The header cannot depend on `--opt`, so a `--opt=dev` build gets the flag
# `--wasm-stack-size=<bytes>` of `roc build`, which replaces the header. The size is in compat/dev-stack-size (2 MiB):
# a dev frame is larger (roc-lang/roc#12922), and the derived CBOR codec of a value nested 50 levels deep overflows 1 MiB (the check "cbor nest").
# The checks (one line each, exit 1 on a failure):
#   1  speed build (the header): the stack is 1 MiB. The check "cbor nest" (50 levels) passes.
#   2  size build (the header): the stack is 1 MiB. The check "cbor nest" passes.
#   3  dev build with the flag: the stack is 2 MiB. The check "cbor nest" passes.
#   4  control: a dev build with no flag has 1 MiB and the check "cbor nest" fails (the check is able to fail).
# Usage: bench/stack-modes.sh [<speed conformance.wasm>]. The default is bench/out/conformance.wasm (bench/build.sh).
# The other builds go to .cache/out-modes/. Env: ROC (default: bench/get-roc.sh). SKIP_SIZE=1 leaves out check 2.
set -uo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
speed=${1:-bench/out/conformance.wasm}
dev_stack=$(cat compat/dev-stack-size)
header_stack=$(sed -n 's/^[[:space:]]*initial_stack_size:[[:space:]]*\([0-9]*\),.*/\1/p' bench/platform/main.roc)
out=.cache/out-modes
mkdir -p "$out"
rc=0
say() { printf '%s  %s\n' "$1" "$2"; [ "$1" = FAIL ] && rc=1; }
build() { # name, flags...
  local name=$1; shift
  "$ROC" build --target=wasm32 --no-cache "$@" --output="$out/$name.wasm" conformance/app.roc > "$out/$name.log" 2>&1
  local code=$?
  [ "$code" -eq 0 ] || [ "$code" -eq 2 ] || { say FAIL "build $name (exit $code, $out/$name.log)"; return 1; }
}
nest() { node conformance/run.mjs "$1" "cbor nest" > "$out/nest.log" 2>&1; }
[ "$dev_stack" -gt "$header_stack" ] || say FAIL "compat/dev-stack-size ($dev_stack) is not above the header ($header_stack)"
[ "$header_stack" = 1048576 ] || say FAIL "the header has initial_stack_size $header_stack, not 1048576 (1 MiB)"

if node bench/check-layout.mjs --stack "$header_stack" "$speed" > "$out/layout.log" 2>&1; then say PASS "speed: stack $header_stack (1 MiB, the header)"; else say FAIL "speed: stack is not $header_stack: $(cat "$out/layout.log")"; fi
if nest "$speed"; then say PASS "speed: cbor nest (50 levels) works"; else say FAIL "speed: cbor nest: $(tail -3 "$out/nest.log")"; fi

if [ -z "${SKIP_SIZE:-}" ] && build conformance-size --opt=size; then
  if node bench/check-layout.mjs --stack "$header_stack" "$out/conformance-size.wasm" > "$out/layout.log" 2>&1; then say PASS "size: stack $header_stack (1 MiB, the header)"; else say FAIL "size: stack is not $header_stack: $(cat "$out/layout.log")"; fi
  if nest "$out/conformance-size.wasm"; then say PASS "size: cbor nest (50 levels) works"; else say FAIL "size: cbor nest: $(tail -3 "$out/nest.log")"; fi
fi

if build conformance-dev2m --opt=dev "--wasm-stack-size=$dev_stack"; then
  if node bench/check-layout.mjs --stack "$dev_stack" "$out/conformance-dev2m.wasm" > "$out/layout.log" 2>&1; then say PASS "dev with the flag: stack $dev_stack (compat/dev-stack-size)"; else say FAIL "dev with the flag: stack is not $dev_stack: $(cat "$out/layout.log")"; fi
  if nest "$out/conformance-dev2m.wasm"; then say PASS "dev with the flag: cbor nest (50 levels) works"; else say FAIL "dev with the flag: cbor nest: $(tail -3 "$out/nest.log")"; fi
fi

if build conformance-dev1m --opt=dev; then
  if node bench/check-layout.mjs --stack "$header_stack" "$out/conformance-dev1m.wasm" > "$out/layout.log" 2>&1; then say PASS "control: dev with no flag has the stack of the header ($header_stack)"; else say FAIL "control: dev with no flag: $(cat "$out/layout.log")"; fi
  if nest "$out/conformance-dev1m.wasm"; then say FAIL "control: cbor nest passes in a dev build with 1 MiB: the check cannot fail (roc-lang/roc#12922 fixed? then the flag is not needed)"; else say PASS "control: cbor nest fails in a dev build with 1 MiB"; fi
fi
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "FAIL"
exit "$rc"
