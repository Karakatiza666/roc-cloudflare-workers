## v3: parse a structural tag union with a `{}` payload.
main! = |_args| {
	r : Try([Ok({}), Err([A])], _)
	r = Json.parse("{\"Ok\":{}}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
