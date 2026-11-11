#!/usr/bin/env bash
# Check that each value of the `packages` block of a platform header is an https:// URL (audit 0.0.10, B1).
# A local path (for example a roc-cbor checkout) builds on this machine only: a bundle with it does not build on another machine.
# Usage: scripts/check-packages.sh [platform/main.roc]. Exit 1 and one line for each bad value.
set -euo pipefail
file=${1:-$(dirname "$0")/../platform/main.roc}
values=$(awk '/^[[:space:]]*packages[[:space:]]*\{/ { on = 1; next } on && /^[[:space:]]*\}/ { exit } on' "$file" |
  sed -n 's/^[[:space:]]*\([a-z_][a-z0-9_]*\)[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1 \2/p')
[ -n "$values" ] || { echo "FAIL: $file: no packages block with name: \"value\" lines" >&2; exit 1; }
bad=0
while read -r name value; do
  case $value in
    https://*) ;;
    *) echo "FAIL: $file: package $name is not an https:// URL: $value" >&2; bad=1 ;;
  esac
done <<<"$values"
exit "$bad"
