## Backing `F64`, bare: W has no encoder_for, so the encode must not compile.
W :: F64

main! = |_args| {
	echo!(Json.to_str(W.(1.5.F64)))
	Ok({})
}
