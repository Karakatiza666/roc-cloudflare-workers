## v5_str: control, the payload is Str.
main! = |_args| {
	r : Try([W(Str)], _)
	r = Json.parse("{\"W\":\"x\"}")
	echo!(Str.inspect(r.is_ok()))
	Ok({})
}
