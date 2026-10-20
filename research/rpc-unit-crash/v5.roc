## v5: the smallest. Parse a one-tag union whose payload is `{}`.
main! = |_args| {
	r : Try([W({})], _)
	r = Json.parse("{\"W\":{}}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
