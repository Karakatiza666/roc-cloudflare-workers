## Compiler probe: how an F64 prints (the numbers of a vector go to JSON text with `to_str`).
main! = |_args| {
	xs : List(F64)
	xs = [0.5, 1.0, 1e-7, 123456789.125, 1e21]
	echo!(Str.join_with(xs.map(|f| f.to_str()), " "))
	Ok({})
}
