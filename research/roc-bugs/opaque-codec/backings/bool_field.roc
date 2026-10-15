## Backing `Bool`, field: W has no encoder_for, so the encode must not compile.
W :: Bool

main! = |_args| {
	echo!(Json.to_str({ v: W.(Bool.True) }))
	Ok({})
}
