## v6: encode a one-tag union whose payload is `{}`.
main! = |_args| {
	v : [W({})]
	v = W({})
	echo!(Json.to_str(v))
	Ok({})
}
