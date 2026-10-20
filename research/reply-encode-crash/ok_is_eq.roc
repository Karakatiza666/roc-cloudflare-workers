W(a) := a.{
	is_eq : _
}

f = |r| |{}| W.(r) == W.(r)

main! = |_args| {
	echo!(Str.inspect(f(7.U64)({})))
	Ok({})
}
