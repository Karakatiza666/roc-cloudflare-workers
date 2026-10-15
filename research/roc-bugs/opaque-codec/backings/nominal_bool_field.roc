## Backing `Bool`, field, nominal (`:=`, not opaque). W has no encoder_for, so it must not compile.
W := Bool

main! = |_args| {
	echo!(Json.to_str({ v: W.(Bool.True) }))
	Ok({})
}
