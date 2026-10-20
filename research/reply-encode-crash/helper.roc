W(a) := a.{
	encoder_for : _
}

enc = |r| Json.to_str(W.(r))

f = |r| |{}| enc(r)

main! = |_args| {
	echo!(f(7.U64)({}))
	Ok({})
}
