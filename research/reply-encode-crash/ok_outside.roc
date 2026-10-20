W(a) := a.{
	encoder_for : _
}

f = |r| {
	s = Json.to_str(W.(r))
	|{}| s
}

main! = |_args| {
	echo!(f(7.U64)({}))
	Ok({})
}
