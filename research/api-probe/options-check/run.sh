#!/bin/sh
# Usage: ROC=<path to roc> ./run.sh
set -e
cd "$(dirname "$0")"
"$ROC" check optional.roc
[ "$("$ROC" optional.roc)" = "a noneb {\"v\":1}nonetext/plain" ] || { echo "options-check: FAIL (output)"; exit 1; }
if "$ROC" check untyped.roc > /dev/null 2>&1; then echo "options-check: FAIL (untyped.roc compiles)"; exit 1; fi
echo "options-check: pass"
