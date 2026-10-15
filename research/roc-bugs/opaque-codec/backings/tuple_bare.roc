## Backing `(Str, U64)`, bare: W has no encoder_for, so the encode must not compile.
W :: (Str, U64)

main! = |_args| {
	echo!(Json.to_str(W.(("x", 7))))
	Ok({})
}
