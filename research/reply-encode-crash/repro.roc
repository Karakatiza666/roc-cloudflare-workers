W(a) := a.{
	encoder_for : _
}

f = |r| |{}| Json.to_str(W.(r))

main! = |_args| {
	echo!(f(7.U64)({}))
	Ok({})
}
