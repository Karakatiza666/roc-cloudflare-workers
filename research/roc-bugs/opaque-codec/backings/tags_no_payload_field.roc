## Backing `[A, B]`, field: W has no encoder_for, so the encode must not compile.
W :: [A, B]

main! = |_args| {
	echo!(Json.to_str({ v: W.(B) }))
	Ok({})
}
