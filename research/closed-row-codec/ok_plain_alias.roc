Ab : [A, B]

enc : Ab -> Str
enc = |x| Json.to_str(x)

main! = |_args| {
	echo!(enc(A))
	Ok({})
}
