## v1: no generic function. Parse a nominal tag union with a `{}` payload.
Reply := [Ok({}), Err([A])].{
	parser_for : _
}

main! = |_args| {
	r : Try(Reply, _)
	r = Json.parse("{\"Ok\":{}}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
