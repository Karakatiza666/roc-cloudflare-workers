#!/usr/bin/env bash
# Download a Roc nightly once and print the path of its `roc`.
# Usage: bench/get-roc.sh [tag]. The default tag is in compat/last-stack-first-nightly.
# Needs `gh` (in CI: GH_TOKEN).
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:-$(cat compat/last-stack-first-nightly)}
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) plat=linux_x86_64 ;;
  Linux-aarch64) plat=linux_arm64 ;;
  Darwin-arm64) plat=macos_apple_silicon ;;
  Darwin-x86_64) plat=macos_x86_64 ;;
  *) echo "no nightly for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
dir=$PWD/.cache/nightlies/$tag
if [ ! -x "$dir/roc" ]; then
  dl=$(mktemp -d)
  gh release download "$tag" -R roc-lang/nightlies -p "*${plat}*.tar.gz" -D "$dl" >&2
  tar xzf "$dl"/*.tar.gz -C "$dl"
  mkdir -p "$dir"
  mv "$(find "$dl" -name roc -type f)" "$dir/roc"
  rm -rf "$dl"
fi
echo "$dir/roc"
