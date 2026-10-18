import pf.Rpc

M :: [].{
	rpc : List(Rpc.Handler({}))
	rpc = [ping.on(ping!)]
}

ping : Rpc({}, U64, [Busy])
ping = Rpc.method("ping")

ping! : {}, {} => Try(U64, [Busy])
ping! = |{}, {}| Err(Busy)
