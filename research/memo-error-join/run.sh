#!/bin/bash
# Type-check each probe with nightly 10-19 and 10-26. Usage: ./run.sh
cd "$(dirname "$0")" && . ./env.sh
for d in min variants/*/; do
	for r in "$R19" "$R26"; do
		t=${r#*nightly-}; t=${t%%/*}
		out=$(cd "$d" && "$r" check --no-cache main.roc 2>&1 | tail -2 | tr -d '\n' | sed 's/─//g')
		echo "${d%/} $t:$out"
	done
done
