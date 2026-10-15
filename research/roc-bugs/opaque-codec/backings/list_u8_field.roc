## Backing `List(U8)`, field: W has no encoder_for, so the encode must not compile.
W :: List(U8)

main! = |_args| {
	echo!(Json.to_str({ v: W.([1, 2]) }))
	Ok({})
}
