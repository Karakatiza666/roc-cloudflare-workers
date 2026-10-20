dec : Str -> Try([A, B], _)
dec = |s| Json.parse(s)

main! = |_args| {
	echo!(Str.inspect(dec("\"A\"")))
	Ok({})
}
