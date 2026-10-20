Ab(r) : [A, B, ..r]

x : Ab([])
x = A

main! = |_args| {
	echo!(Json.to_str(x))
	Ok({})
}
