## Backing `Try(U64, Str)`, bare: W has no encoder_for, so the encode must not compile.
W :: Try(U64, Str)

main! = |_args| {
	echo!(Json.to_str(W.(Ok(7))))
	Ok({})
}
