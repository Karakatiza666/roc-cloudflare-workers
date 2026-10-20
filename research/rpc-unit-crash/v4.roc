## v4: a nominal wrapper of `{}` only.
W := [W({})].{
	parser_for : _
}

main! = |_args| {
	r : Try(W, _)
	r = Json.parse("{\"W\":{}}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
