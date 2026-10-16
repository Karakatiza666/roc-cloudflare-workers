#!/usr/bin/env bash
# Build the bench apps in a copy of the repo (research/memmap/.work) and write, for each one:
#   out/<name>.wasm   as bench/build.sh makes it (same bytes: checked by cmp when bench/out has the file)
#   out/<name>.map    the wasm-ld map (symbol addresses), from the same link, run again with -Map
# Names: app, app_deep (bench apps), app_boxy (bench/app.roc with `--specialize=no`: the boxy runtime is linked in).
# Env: ZIG (Zig 0.17), ROC (default: the nightly of compat/last-stack-first-nightly), NAMES.
# The bench host and the bench platform (bench/platform/main.roc). The tree is not touched: no bench/build.sh and no zig build there.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../.." && pwd)
ZIG=${ZIG:-zig}
W=$D/.work
mkdir -p "$W" "$D/out"
rsync -a --delete --exclude .git --exclude research --exclude .zig-cache --exclude .cache --exclude bench/out "$R/" "$W/"
cd "$W"
export ROC_CACHE_DIR=$W/.cache/roc XDG_CACHE_HOME=$W/.cache ZIG_GLOBAL_CACHE_DIR=$W/.cache/zig
ROC=${ROC:-$R/.cache/nightlies/$(cat compat/last-stack-first-nightly)/roc}
"$ROC" glue host/ZigGlue.roc .cache/glue platform/main.roc >/dev/null
cp .cache/glue/roc_platform_abi.zig host/roc_platform_abi.zig
"$ZIG" build -Dbench=true   # the bench host (PLAN.md 7a): memmap.mjs uses the test exports
# The linker flags that roc passes for wasm32 (roc:src/cli/linker.zig, "freestanding").
STACK=$(sed -n 's/^[[:space:]]*initial_stack_size:[[:space:]]*\([0-9]*\),.*/\1/p' bench/platform/main.roc)
EXPORTS=$(grep -o 'exports: \[[^]]*\]' bench/platform/main.roc | sed 's/exports: \[//; s/\]//; s/"//g; s/, */ /g')
EA=(); for e in $EXPORTS; do EA+=("--export=$e"); done
for name in ${NAMES:-app app_deep app_boxy}; do
  src=bench/$name.roc; flags=()
  if [ "$name" = app_boxy ]; then src=bench/app.roc; flags=(--specialize=no); fi
  # Exit 2: warnings only (the dbg in bench/app.roc).
  "$ROC" build --opt=speed --target=wasm32 --no-cache "${flags[@]}" --output="$D/out/$name.wasm" "$src" >/dev/null || [ $? -eq 2 ]
  # The same build with --keep-temp, in its own cache dir, to get the object files of the link.
  export ROC_CACHE_DIR=$W/.cache/map-$name
  "$ROC" build --opt=speed --target=wasm32 --no-cache --keep-temp "${flags[@]}" --output="$W/.cache/$name.tmp.wasm" "$src" >/dev/null 2>&1 || [ $? -eq 2 ]
  export ROC_CACHE_DIR=$W/.cache/roc
  OBJ=$(ls -td "$W"/.cache/map-"$name"/*/tmp/*/ | head -1)
  "$ZIG" wasm-ld -o "$W/.cache/$name.link.wasm" --no-entry --gc-sections --import-undefined --strip-all -z stack-size="$STACK" \
    "${EA[@]}" -Map="$D/out/$name.map" bench/platform/targets/wasm32/host.wasm "$OBJ/roc_app_composed_wasm32.o"
  echo "built $name"
done
if [ -f "$R/bench/out/app.wasm" ]; then
  for name in app app_deep; do cmp -s "$D/out/$name.wasm" "$R/bench/out/$name.wasm" && echo "$name: same bytes as bench/out" || echo "$name: differs from bench/out (the host changed?)"; done
fi
