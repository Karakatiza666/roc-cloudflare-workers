## Backing `List(U8)`, bare: W has no encoder_for, so the encode must not compile.
W :: List(U8)

main! = |_args| {
	echo!(Json.to_str(W.([1, 2])))
	Ok({})
}
