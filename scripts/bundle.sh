#!/usr/bin/env bash
# Make the release files in dist/ (PLAN.md 11a):
#   dist/<hash>.tar.zst                      the platform bundle: platform/*.roc, LICENSE, targets/wasm32/host.wasm
#   dist/roc-cloudflare-workers-<ver>.tgz    the js/ package (npm pack: `npm install <file or URL>` takes it)
# Steps: the glue is the glue of the pinned nightly, the production host (zig build), a production app on it
# (bench/app.roc) with the layout and export checks, the bundle, the package.
# Usage: ZIG=<zig 0.17> [ROC=<roc>] [REPO=<owner/repo>] scripts/bundle.sh [version]
# The default version is the tag of HEAD, else 0.0.0-local. The default ROC is the nightly of compat/last-stack-first-nightly.
# The last lines are `asset:`, `url:`, `shim:`, `shim_url:` (the release workflow reads them).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ZIG:?set ZIG to the Zig 0.17 binary}"
version=${1:-$(git describe --tags --exact-match 2>/dev/null || echo 0.0.0-local)}
repo=${REPO:-${GITHUB_REPOSITORY:-Karakatiza666/roc-cloudflare-workers}}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "bad version: $version (X.Y.Z or X.Y.Z-pre)" >&2; exit 1; }
ROC=${ROC:-$(bench/get-roc.sh)}
# The package cache (http, cbor) is XDG_CACHE_HOME/roc/packages. ROC_CACHE_DIR is the build cache.
export ROC_CACHE_DIR=${ROC_CACHE_DIR:-$PWD/.cache/roc} XDG_CACHE_HOME=${XDG_CACHE_HOME:-$PWD/.cache} ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$PWD/.cache/zig}
work=.cache/release
rm -rf "$work" dist
mkdir -p "$work" dist

# 1. The glue must equal the committed file (the same check as bench/ci-layout.sh).
ROC=$ROC bench/glue.sh "$work/glue" >&2
diff -u host/roc_platform_abi.zig "$work/glue/roc_platform_abi.zig" >&2 ||
  { echo "FAIL: host/roc_platform_abi.zig is not the glue of $("$ROC" version). Run bench/build.sh and commit it." >&2; exit 1; }

# 2. The production host: platform/targets/wasm32/host.wasm.
"$ZIG" build >&2
test -s platform/targets/wasm32/host.wasm

# 3. A production app (bench/app.roc on platform/main.roc): the stack is first, with the size of the header,
# and the export section is the production list (7a). `--no-cache`: a warm build cache gave other code (r11 status).
sed '1s|platform "platform/main.roc"|platform "../platform/main.roc"|' bench/app.roc > bench/app_prod.roc
"$ROC" build --opt=speed --target=wasm32 --no-cache --output="$work/app_prod.wasm" bench/app_prod.roc >&2 || [ $? -eq 2 ]
node bench/check-layout.mjs --header platform/main.roc "$work/app_prod.wasm" >&2
node bench/exports-test.mjs "$work/app_prod.wasm" >&2

# 4. The bundle. A stage directory holds exactly the files of the bundle. `roc bundle` follows the imports of
# main.roc. The header packages (http, cbor) stay URLs: the bundle has no copy of them.
stage="$work/stage"
mkdir -p "$stage/targets/wasm32"
cp platform/*.roc "$stage/"
cp LICENSE "$stage/LICENSE"
cp platform/targets/wasm32/host.wasm "$stage/targets/wasm32/host.wasm"
(cd "$stage" && "$ROC" bundle main.roc LICENSE targets/wasm32/host.wasm --output-dir "$OLDPWD/dist" >&2)
asset=$(echo dist/*.tar.zst)
zstd -dc "$asset" | tar -t | grep -v '^[A-Z][A-Za-z0-9]*\.roc$' >&2
if zstd -dc "$asset" | tar -t | grep -E '(^|/)(http|cbor)(/|$)|\.\./'; then echo "FAIL: the bundle has a copy of a package or a path out" >&2; exit 1; fi

# 5. The js/ package, with the version of the release. The source file keeps 0.0.0-dev. The command
# `roc-cloudflare-workers` (js/cli.mjs) takes `init` from template/ (the files of examples/hello) and the URLs of this
# release from release.json.
pkg="$work/js"
mkdir -p "$pkg/template"
cp js/*.js js/*.mjs js/package.json "$pkg/"
cp LICENSE "$pkg/LICENSE"
cp examples/hello/{main.roc,worker.js,wrangler.toml,package.json} "$pkg/template/"
node -e '
  const [file, version, platform, shim] = process.argv.slice(1);
  require("fs").writeFileSync(file, JSON.stringify({ version, platform, shim }, null, 2) + "\n");
' "$pkg/release.json" "$version" "https://github.com/$repo/releases/download/$version/$(basename "$asset")" "https://github.com/$repo/releases/download/$version/roc-cloudflare-workers-$version.tgz"
node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  p.version = process.argv[2];
  fs.writeFileSync(process.argv[1], JSON.stringify(p, null, 2) + "\n");
' "$pkg/package.json" "$version"
(cd "$pkg" && npm pack --silent --pack-destination "$OLDPWD/dist" >&2)
shim=dist/roc-cloudflare-workers-$version.tgz
test -s "$shim"
tar -tzf "$shim" >&2

echo "asset: $asset"
echo "url: https://github.com/$repo/releases/download/$version/$(basename "$asset")"
echo "shim: $shim"
echo "shim_url: https://github.com/$repo/releases/download/$version/$(basename "$shim")"
