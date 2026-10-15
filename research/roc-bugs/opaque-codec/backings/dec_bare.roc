## Backing `Dec`, bare: W has no encoder_for, so the encode must not compile.
W :: Dec

main! = |_args| {
	echo!(Json.to_str(W.(1.5)))
	Ok({})
}
