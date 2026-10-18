app [event!] {
	pf: platform "../../platform/main.roc",
}

## Q1: the handler type is self, arg => Try(ret, err). A foreign error tag must not compile.
import pf.Worker
import pf.Cbor

Rpc3(arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc3(arg, ret, err)
	method = |name| Rpc3.{ name }

	on : Rpc3(arg, ret, err), (self, arg => Try(ret, err)) -> { name : Str } where [arg.Cbor.Parseable([InvalidCbor(U64), ..errs]), ret.Cbor.Encodable([]), err.Cbor.Encodable([])]
	on = |m, _f!| { name: m.name }
}

Closeout : { n : U64 }
close_out : Rpc3({}, Closeout, [StillOpen, NotOpen])
close_out = Rpc3.method("close_out")

good = Rpc3.on(close_out, |_self, _a| Err(StillOpen))
good2 = Rpc3.on(close_out, |_self, _a| Ok({ n: 1 }))
bad = Rpc3.on(close_out, |_self, _a| Err(Busy))

# an unannotated Err(Null) in a tuple
t = Cbor.encode((7.I64, Err(Null), "x"))

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
