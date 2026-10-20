W := [W(U64)].{
	encoder_for : _
}

f = |r| |{}| Json.to_str(W.W(r))

main! = |_args| {
	echo!(f(7)({}))
	Ok({})
}
