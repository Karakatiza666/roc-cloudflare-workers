#!/bin/sh
# Run the repros of the two compiler bugs on one or more nightlies.
# Usage: ./run.sh <path to roc> [<path to roc> ...]
# Each case has the result that the docs give: "reject" (a compile error) or "run" (it compiles).
# "crash" is a crash of the compiler.
# A line with "BUG" is a case where the compiler does not do that.
cd "$(dirname "$0")"
cases="
opaque-codec/repro.roc reject
opaque-codec/field.roc reject
opaque-codec/field_Id.roc reject
opaque-codec/field_list.roc reject
opaque-codec/tuple.roc reject
opaque-codec/tag.roc reject
opaque-codec/nominal_field.roc reject
opaque-codec/bare.roc reject
opaque-codec/list.roc reject
opaque-codec/parse_field.roc reject
opaque-codec/parse_tuple.roc reject
opaque-codec/field_record_backing.roc reject
opaque-codec/backings/u8_field.roc reject
opaque-codec/backings/u64_field.roc reject
opaque-codec/backings/i64_field.roc reject
opaque-codec/backings/dec_field.roc reject
opaque-codec/backings/f64_field_try.roc reject
opaque-codec/backings/bool_field.roc reject
opaque-codec/backings/nominal_bool_field.roc reject
opaque-codec/backings/tags_field.roc reject
opaque-codec/backings/tags_no_payload_field.roc reject
opaque-codec/backings/try_field.roc reject
opaque-codec/backings/tuple_field.roc reject
opaque-codec/backings/record_field.roc reject
opaque-codec/backings/list_u8_field.roc reject
opaque-codec/backings/list_str_field.roc reject
opaque-codec/backings/over_nominal_field.roc reject
opaque-codec/backings/plain_bool_field.roc run
type-not-determined/tiny.roc run
type-not-determined/tiny_annotated.roc run
type-not-determined/tiny_one_format.roc run
"
for roc in "$@"; do
	echo "== $("$roc" version)"
	echo "$cases" | while read -r file want; do
		[ -z "$file" ] && continue
		dir=$(dirname "$file"); base=$(basename "$file")
		if out=$(cd "$dir" && "$roc" "$base" 2>&1); then got=run; else got=reject; fi
		case "$out" in *"in the Roc compiler"*) got=crash ;; esac
		if [ "$got" = "$want" ]; then mark=ok; else mark=BUG; fi
		first=$(echo "$out" | grep -m1 -E '✗|SIGSEGV|^\{|^\[|^Ok|^Err' | sed 's/─//g; s/  */ /g' | cut -c1-60)
		printf '%-4s %-44s want %-6s got %-6s %s\n' "$mark" "$file" "$want" "$got" "$first"
	done
done
