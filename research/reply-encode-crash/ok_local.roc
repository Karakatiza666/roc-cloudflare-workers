W(a) := [W(a)].{
	encoder_for : _
}

main! = |_args| {
	r = 7.U64
	g = |{}| Json.to_str(W.W(r))
	echo!(g({}))
	Ok({})
}
