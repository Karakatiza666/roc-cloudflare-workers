## Option A, must not compile: an `Rpc` constant with a free `iface` (one method for two interfaces).

Rpc(iface, arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc(iface, arg, ret, err)
	method = |name| Rpc.{ name }
}

ping : Rpc(iface, {}, Str, [])
ping = Rpc.method("ping")

main! = |_args| {
	echo!(Str.inspect(ping))
	Ok({})
}
