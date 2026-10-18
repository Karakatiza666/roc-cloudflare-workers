#!/usr/bin/env bash
# Build one tiny app cold, warm and with --no-cache, and compare the binaries and their output.
# Usage: repro.sh [nightly-tag]. Default: the pinned nightly. Exit 1: the warm binary differs from the --no-cache binary.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=$("$here/../../bench/get-roc.sh" "$@")
work=$(mktemp -d "$here/work.XXXXXX"); trap 'rm -rf "$work"' EXIT
cp "$here/main.roc" "$here/Lib.roc" "$work/"; cd "$work"
export ROC_CACHE_DIR=$work/cache XDG_CACHE_HOME=$work/xdg   # private, empty cache
"$roc" version
b() { "$roc" build "${@:2}" --output="$1" main.roc >/dev/null 2>&1; }
b cold; b warm; b nocache --no-cache
# Edit a source file: the warm build must compile Lib again.
sed -i 's/80\]/90]/' Lib.roc
b warm_edit; b nocache_edit --no-cache
printf '%-12s %8s  %-12s %s\n' build bytes sha256 output
for f in cold warm nocache warm_edit nocache_edit; do
  printf '%-12s %8s  %-12s %s\n' "$f" "$(stat -c %s $f)" "$(sha256sum $f | cut -c1-12)" "$(./$f)"
done
# The data symbols show the difference: the cold build keeps one more constant block.
echo "data symbols (cold): $(nm cold | grep -c ' roc__d')  (warm): $(nm warm | grep -c ' roc__d')"
if [ "$(sha256sum <warm)" != "$(sha256sum <nocache)" ] || [ "$(sha256sum <warm_edit)" != "$(sha256sum <nocache_edit)" ]; then
  echo "BUG: the cached build differs from the --no-cache build of the same source"; exit 1
fi
echo "no difference"
