## Backing `[A, B(U64)]`, field: W has no encoder_for, so the encode must not compile.
W :: [A, B(U64)]

main! = |_args| {
	echo!(Json.to_str({ v: W.(B(7)) }))
	Ok({})
}
