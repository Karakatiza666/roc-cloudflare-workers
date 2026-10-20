import Fmt

Reply(a) := [Ok(a)].{
	encoder_for : _
}

on : r -> ({} -> List(U8)) where [r.Fmt.Writable]
on = |r| |{}| Fmt.encode(Reply.Ok(r))

main! = |_args| {
	echo!(Str.inspect(on(7.U64)({})))
	Ok({})
}
