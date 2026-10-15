## Backing `I64`, bare: W has no encoder_for, so the encode must not compile.
W :: I64

main! = |_args| {
	echo!(Json.to_str(W.(-7)))
	Ok({})
}
