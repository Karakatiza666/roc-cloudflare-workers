import Fmt

Reply(a) := [Ok(a)].{
	encoder_for : _
}

main! = |_args| {
	echo!(Str.inspect(Fmt.encode(Reply.Ok(7.U64))))
	Ok({})
}
