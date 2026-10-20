W(a) := [W(a)].{
	encoder_for : _
}

f = |r| |{}| Json.to_str(W.W(r))

main! = |_args| {
	g = f(7.U64)
	echo!(g({}))
	Ok({})
}
