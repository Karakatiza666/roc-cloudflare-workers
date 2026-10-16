#!/usr/bin/env bash
# Make the glue: `roc glue` on host/ZigGlue.roc and platform/main.roc, then the notice header.
# Writes <out_dir>/roc_platform_abi.zig. bench/build.sh copies it to host/, bench/ci-layout.sh compares it.
# Usage: bench/glue.sh <out_dir>. Env: ROC (default: bench/get-roc.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?usage: bench/glue.sh <out_dir>}
ROC=${ROC:-$(bench/get-roc.sh)}
rm -rf "$out"
"$ROC" glue host/ZigGlue.roc "$out/raw" platform/main.roc >/dev/null
# The header has no nightly tag: ci-layout.sh compares the output of each new nightly with the committed file.
{
  cat <<'EOF'
// Generated file. Do not edit. bench/glue.sh makes it (bench/build.sh copies it here):
//   roc glue host/ZigGlue.roc <out_dir> platform/main.roc
// Roc: the nightly in compat/last-stack-first-nightly. Input: host/ZigGlue.roc and the platform types of platform/main.roc.
// Most of this file is fixed template text from host/ZigGlue.roc (a copy of roc:src/glue/src/ZigGlue.roc).
// For that text: Copyright © 2019 Richard Feldman and subsequent Roc authors <roc-lang.org/authors>
// Licensed under the Universal Permissive License (UPL), Version 1.0. See LICENSE.

EOF
  cat "$out/raw/roc_platform_abi.zig"
} > "$out/roc_platform_abi.zig"
