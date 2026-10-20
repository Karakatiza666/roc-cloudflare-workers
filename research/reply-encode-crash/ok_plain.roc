f = |r| |{}| Json.to_str(r)

main! = |_args| {
	echo!(f(7.U64)({}))
	Ok({})
}
