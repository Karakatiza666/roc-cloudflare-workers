#!/usr/bin/env bash
# Build the host, the glue, and the bench apps (bench/out/app.wasm, app_pad.wasm, app_deep.wasm).
# Env: ZIG (Zig 0.17).
# Optional: ROC (default: the nightly in compat/last-stack-first-nightly, see bench/get-roc.sh),
# ZIG_FLAGS (e.g. "-Downer_tag=false -Dtrack_live=false"), OUT (default bench/out).
set -euo pipefail
cd "$(dirname "$0")/.."
ROC=${ROC:-$(bench/get-roc.sh)}
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache ZIG_GLOBAL_CACHE_DIR=$PWD/.cache/zig
"$ROC" glue host/ZigGlue.roc .cache/glue platform/main.roc >/dev/null
cp .cache/glue/roc_platform_abi.zig host/roc_platform_abi.zig
"$ZIG" build ${ZIG_FLAGS:-}
# The padded app: the same app with about 2 MB of data in a data segment.
[ -f bench/pad.txt ] || head -c 1572864 /dev/urandom | base64 -w 0 > bench/pad.txt
python3 - <<'PY'
s = open('bench/app.roc').read()
s = s.replace('import pf.Wait\n', 'import pf.Wait\nimport "pad.txt" as pad : List(U8)\n')
s = s.replace('\t"id=${id} json=', '\tpick = pad.get(json.count_utf8_bytes() % pad.len()) ?? 0\n\t"id=${id} pad=${pick.to_str()} json=', 1)
open('bench/app_pad.roc', 'w').write(s)
PY
OUT=${OUT:-bench/out}
mkdir -p "$OUT"
for app in app app_pad app_deep; do
  # The stack size must match STACK_SIZE in hostlib/canary.zig.
  "$ROC" build --opt=speed --target=wasm32 --wasm-memory=0 --wasm-stack-size=1048576 --no-cache \
    --output="$OUT/$app.wasm" bench/$app.roc
done
ls -l "$OUT"
# The layout check warns only. CI (bench/ci-layout.sh) fails on it.
node bench/check-layout.mjs "$OUT"/app.wasm "$OUT"/app_pad.wasm "$OUT"/app_deep.wasm ||
  echo "WARNING: a build is not stack-first. The platform falls back to an instance per request." >&2
