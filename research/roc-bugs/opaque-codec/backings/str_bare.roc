## Backing `Str`, bare: W has no encoder_for, so the encode must not compile.
W :: Str

main! = |_args| {
	echo!(Json.to_str(W.("x")))
	Ok({})
}
