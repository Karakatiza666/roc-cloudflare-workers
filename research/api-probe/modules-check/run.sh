#!/bin/sh
# Check and run the module prototype on a nightly, and compare the output with expected.txt.
# Usage: ROC=<path to roc> ./run.sh
set -e
cd "$(dirname "$0")"
"$ROC" check app.roc
if "$ROC" check secret_log.roc > /dev/null 2>&1; then echo "modules-check: FAIL (a Secret can be encoded as JSON)"; exit 1; fi
if "$ROC" check secret_cbor.roc > /dev/null 2>&1; then echo "modules-check: FAIL (a Secret can be encoded as CBOR)"; exit 1; fi
if "$ROC" check ref_cbor.roc > /dev/null 2>&1; then echo "modules-check: FAIL (a Js.Ref can be encoded as CBOR)"; exit 1; fi
# The fake shim. The fake JS side writes its visible ops with `dbg` (Io.cross!). After `ctx.respond`,
# the response of `respond!` goes to the client, and the outcome of the handler is ignored (API.md 10.2).
shim() {
	awk '
		/^\[dbg\] "js ctx.respond / { sub(/^\[dbg\] "js ctx.respond /, ""); sub(/"$/, ""); print; responded = 1; next }
		/^\[dbg\] "js / { sub(/^\[dbg\] "/, ""); sub(/"$/, ""); print; next }
		/^outcome / { if (!responded) { sub(/^outcome /, ""); print } responded = 0; next }
		{ print }
	'
}
out=$(mktemp)
("$ROC" app.roc 2>&1 || true) | shim > "$out"
if diff -u expected.txt "$out"; then echo "modules-check: pass"; rm -f "$out"; else rm -f "$out"; echo "modules-check: FAIL"; exit 1; fi
