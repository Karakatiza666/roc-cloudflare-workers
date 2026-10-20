## v2: parse a plain `{}` record.
main! = |_args| {
	r : Try({}, _)
	r = Json.parse("{}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
