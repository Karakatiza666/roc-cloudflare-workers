## Backing `F64`, field, with `to_str_try` (F64 can fail: NaN). W has no encoder_for, so it must not compile.
W :: F64

main! = |_args| {
	echo!(Str.inspect(Json.to_str_try({ v: W.(1.5.F64) })))
	Ok({})
}
