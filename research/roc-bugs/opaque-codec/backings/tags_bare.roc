## Backing `[A, B(U64)]`, bare: W has no encoder_for, so the encode must not compile.
W :: [A, B(U64)]

main! = |_args| {
	echo!(Json.to_str(W.(B(7))))
	Ok({})
}
