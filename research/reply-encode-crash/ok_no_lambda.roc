W(a) := [W(a)].{
	encoder_for : _
}

f = |r| Json.to_str(W.W(r))

main! = |_args| {
	echo!(f(7.U64))
	Ok({})
}
