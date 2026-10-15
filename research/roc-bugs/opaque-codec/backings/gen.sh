#!/bin/sh
# Make one file for each backing type, in a record field and bare. Usage: ./gen.sh
cd "$(dirname "$0")"
while IFS='|' read -r name backing value; do
	[ -z "$name" ] && continue
	for shape in field bare; do
		if [ $shape = field ]; then expr="{ v: W.(${value}) }"; else expr="W.(${value})"; fi
		cat > "${name}_${shape}.roc" <<ROC
## Backing \`${backing}\`, ${shape}: W has no encoder_for, so the encode must not compile.
W :: ${backing}

main! = |_args| {
	echo!(Json.to_str(${expr}))
	Ok({})
}
ROC
	done
done <<'LIST'
str|Str|"x"
u8|U8|7
u64|U64|7
i64|I64|-7
dec|Dec|1.5
f64|F64|1.5.F64
bool|Bool|Bool.True
tags|[A, B(U64)]|B(7)
tags_no_payload|[A, B]|B
list_u8|List(U8)|[1, 2]
list_str|List(Str)|["x"]
tuple|(Str, U64)|("x", 7)
record|{ s : Str }|{ s: "x" }
try|Try(U64, Str)|Ok(7)
LIST
