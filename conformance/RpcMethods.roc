## The `Rpc` constants of the conformance app (MODULES.md 8): each names a method and its types for the caller and the
## callee. `ping` has two callees, the class `Counter` and the default export (`Worker.rpc`).
import pf.Rpc
import cbor.Cbor

RpcMethods :: [].{
	increment : Rpc({ by : I64 }, I64)
	increment = Rpc.method("increment")

	ping : Rpc({ n : I64 }, Str)
	ping = Rpc.method("ping")

	## The callee gives `Err(Nope(n))`: the caller gets `RpcErr` with the message `Nope(n)`.
	boom : Rpc({ n : I64 }, I64)
	boom = Rpc.method("boom")

	## The reply is the argument: a `U64` of 2^60 comes back exact (CBOR, MC5).
	echo : Rpc({ big : U64 }, { big : U64 })
	echo = Rpc.method("echo")

	## A method of the named entry point `Admin`.
	purge : Rpc({ prefix : Str }, Str)
	purge = Rpc.method("purge")

	## A JS method of `conformance/worker.js` (the default export): it gives the JS kinds of the fields of its argument.
	inspect : Rpc({ data : Cbor.Bytes, list : List(U8) }, { data : Str, list : Str })
	inspect = Rpc.method("inspect")

	## A JS method of `conformance/worker.js` that gives a text of `n` bytes (the RPC limit).
	big : Rpc({ n : U64 }, Str)
	big = Rpc.method("big")

	## No callee has it.
	nothere : Rpc({ n : I64 }, I64)
	nothere = Rpc.method("nothere")
}
