## Backing `[A, B]`, bare: W has no encoder_for, so the encode must not compile.
W :: [A, B]

main! = |_args| {
	echo!(Json.to_str(W.(B)))
	Ok({})
}
