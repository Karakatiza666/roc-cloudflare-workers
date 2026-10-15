## Backing `Bool`, bare: W has no encoder_for, so the encode must not compile.
W :: Bool

main! = |_args| {
	echo!(Json.to_str(W.(Bool.True)))
	Ok({})
}
