## Backing `U64`, field: W has no encoder_for, so the encode must not compile.
W :: U64

main! = |_args| {
	echo!(Json.to_str({ v: W.(7) }))
	Ok({})
}
