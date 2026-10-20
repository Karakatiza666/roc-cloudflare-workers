#!/bin/sh
# Run each case on one or more nightlies. Usage: ./run.sh <path to roc> [<path to roc> ...]
cd "$(dirname "$0")"
for roc in "$@"; do
	echo "== $("$roc" version)"
	for f in repro payload parse ok_written ok_plain_alias ok_tag ok_value ok_parse_written open_row open_union; do
		out=$(timeout 600 "$roc" --no-cache "$f.roc" 2>&1)
		case "$out" in
			*"in the Roc compiler"*) got=crash ;;
			*"missing method"*) got="missing method $(echo "$out" | grep -o 'requires the [a-z_]* method' | cut -d' ' -f3)" ;;
			*) got=$(echo "$out" | head -1) ;;
		esac
		printf '%-18s %s\n' "$f" "$got"
	done
done
