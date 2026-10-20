## v8: parse a one-tag union whose payload is a one-field record.
main! = |_args| {
	r : Try([W({ a : U8 })], _)
	r = Json.parse("{\"W\":{\"a\":1}}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
