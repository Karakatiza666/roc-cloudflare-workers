## v7: parse a record with a `{}` field.
main! = |_args| {
	r : Try({ a : {} }, _)
	r = Json.parse("{\"a\":{}}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
