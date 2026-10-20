#!/bin/sh
# Run each case on one or more nightlies. Usage: ./run.sh <path to roc> [<path to roc> ...]
cd "$(dirname "$0")"
for roc in "$@"; do
	echo "== $("$roc" version)"
	for f in repro tag custom_format helper custom_format_ok ok_no_lambda ok_mono ok_local ok_outside ok_plain ok_is_eq; do
		out=$("$roc" --no-cache "$f.roc" 2>&1)
		case "$out" in *"in the Roc compiler"*) got=crash ;; *) got=$(echo "$out" | head -1) ;; esac
		printf '%-18s %s\n' "$f" "$got"
	done
done
