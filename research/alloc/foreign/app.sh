#!/usr/bin/env bash
# Build the registry copy on a host with foreign backend <b> (or "base": hostlib/alloc.zig, or a file path):
# gen.sh, then ../variant-app.sh with SUM_OFF=1, then the shim copy of <REG>/w2-<name> takes resumeCheck "off"
# (the release host refuses it; research only). Usage: ZIG=<zig 0.17> REG=<reg dir> foreign/app.sh <b|base|file.zig> [name]
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
A=$(cd "$D/.." && pwd)
b=$1
case $b in
  base) src=$A/../../hostlib/alloc.zig; name=${2:-base} ;;
  *.zig) src=$(cd "$(dirname "$b")" && pwd)/$(basename "$b"); name=${2:-$(basename "$b" .zig)} ;;
  *) "$D/gen.sh" "$b"; src=$D/gen/fa_$b.zig; name=${2:-fa_$b}
     export EXTRA_ZIG="$D/fa_tl.zig"
     [ -f "$D/gen/$b.o" ] && export EXTRA_OBJ=$D/gen/$b.o ;;
esac
SUM_OFF=1 "$A/variant-app.sh" "$src" "$name"
f=$REG/w2-$name/.roc-cfw/index.js
grep -q "runnerOpts.resumeCheck === 'off' && !isBenchHost(module)" "$f"
sed -i "s/runnerOpts.resumeCheck === 'off' \&\& !isBenchHost(module)/false/" "$f"
echo "app $name: $REG/w2-$name"
