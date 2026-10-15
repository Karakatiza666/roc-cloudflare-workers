## Backing `F64`, bare, with `to_str_try`. W has no encoder_for, so it must not compile.
W :: F64

main! = |_args| {
	echo!(Str.inspect(Json.to_str_try(W.(1.5.F64))))
	Ok({})
}
