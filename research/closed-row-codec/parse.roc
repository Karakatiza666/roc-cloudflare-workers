Ab(r) : [A, B, ..r]

dec : Str -> Try(Ab([]), _)
dec = |s| Json.parse(s)

main! = |_args| {
	echo!(Str.inspect(dec("\"A\"")))
	Ok({})
}
