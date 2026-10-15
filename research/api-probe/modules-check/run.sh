#!/bin/sh
# Check and run the module prototype on a nightly, and compare the output with expected.txt.
# Usage: ROC=<path to roc> ./run.sh
set -e
cd "$(dirname "$0")"
"$ROC" check app.roc
if "$ROC" check secret_log.roc > /dev/null 2>&1; then echo "modules-check: FAIL (a Secret can be encoded as JSON)"; exit 1; fi
if "$ROC" check secret_cbor.roc > /dev/null 2>&1; then echo "modules-check: FAIL (a Secret can be encoded as CBOR)"; exit 1; fi
out=$(mktemp)
"$ROC" app.roc > "$out" 2>&1 || true
if diff -u expected.txt "$out"; then echo "modules-check: pass"; rm -f "$out"; else rm -f "$out"; echo "modules-check: FAIL"; exit 1; fi
