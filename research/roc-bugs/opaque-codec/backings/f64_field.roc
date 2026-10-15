## Backing `F64`, field: W has no encoder_for, so the encode must not compile.
W :: F64

main! = |_args| {
	echo!(Json.to_str({ v: W.(1.5.F64) }))
	Ok({})
}
