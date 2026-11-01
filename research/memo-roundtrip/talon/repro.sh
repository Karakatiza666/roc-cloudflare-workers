#!/usr/bin/env bash
# Build a copy of the Talon registry Worker with KeySet = { fetched_ms, keys : List(Jwk.Key) } and run its oidc W2 cases.
# Usage: repro.sh [w2 filter...]. Env OPT: dev (default, as Talon W2) or speed. Env PF: a platform main.roc to use in place of the 0.0.2 release URL (optional).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=/home/george/dev/Karakatiza666/talon
. "$T/scripts/env.sh"
ROC=$T/cloudflare-workers/.cache/nightlies/$ROC_TAG_WORKER/roc
B=$HERE/../../../.cache/talon-repro
rm -rf "$B"; mkdir -p "$B"
rsync -a --exclude app.wasm --exclude .roc-cfw --exclude .wrangler "$T/worker/" "$B/worker/"
rsync -a "$T/packages/" "$B/packages/"
python3 -I "$HERE/keys-variant.py" "$B/worker"
hash=$(sed -n 's#.*roc-cloudflare-workers/releases/download/[^/]*/\([A-Za-z0-9]*\)\.tar\.zst.*#\1#p' "$B/worker/main.roc" | head -n 1)
if [ -n "${PF:-}" ]; then
  sed -i "s#pf: platform \"[^\"]*\"#pf: platform \"$PF\"#" "$B/worker/main.roc"
fi
( cd "$B/worker" && "$ROC" build --target=wasm32 --no-cache --opt=${OPT:-dev} --output=app.wasm main.roc > "$B/build.log" 2>&1 ) || { tail -40 "$B/build.log"; exit 1; }
if [ -n "${PF:-}" ]; then cp -r "$(dirname "$PF")/../js" "$B/worker/.roc-cfw"; else cp -r "$ROC_CACHE_DIR/packages/$hash/js" "$B/worker/.roc-cfw"; fi
W2_DIR=$B/worker node "$T/worker/tests/run.mjs" "${@:-oidc}"
