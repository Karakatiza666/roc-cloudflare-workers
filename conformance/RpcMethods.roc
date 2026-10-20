## The `Rpc` constants of the conformance app (MODULES.md 8): each names a method and its types for the caller and the
## callee. `ping` has two callees, the class `Counter` and the default export (`Worker.rpc`).
import pf.Rpc
import pf.Cbor
import pf.Io

RpcMethods :: [].{
	increment : Rpc({ by : I64 }, I64, [Infra(Rpc.Infra)])
	increment = Rpc.method("increment")

	ping : Rpc({ n : I64 }, Str, Rpc.NoErr)
	ping = Rpc.method("ping")

	## The callee gives `Err(Nope(n))`: the caller gets `Err(Remote(Nope(n)))`.
	boom : Rpc({ n : I64 }, I64, [Nope(I64)])
	boom = Rpc.method("boom")

	## The reply is the argument: a `U64` of 2^60 comes back exact (CBOR, MC5).
	echo : Rpc({ big : U64 }, { big : U64 }, Rpc.NoErr)
	echo = Rpc.method("echo")

	## A method of the named entry point `Admin`.
	purge : Rpc({ prefix : Str }, Str, Rpc.NoErr)
	purge = Rpc.method("purge")

	## A JS method of `conformance/worker.js` (the default export): it gives the JS kinds of the fields of its argument.
	inspect : Rpc({ data : Cbor.Bytes, list : List(U8) }, { data : Str, list : Str }, Rpc.NoErr)
	inspect = Rpc.method("inspect")

	## A JS method of `conformance/worker.js` that gives a text of `n` bytes (the RPC limit).
	big : Rpc({ n : U64 }, Str, Rpc.NoErr)
	big = Rpc.method("big")

	## FO6 (PLAN.md 8f): a method whose argument type is `{}` takes a JS call with no argument (`stub.hello()`).
	hello : Rpc({}, Str, Rpc.NoErr)
	hello = Rpc.method("hello")

	## No callee has it.
	nothere : Rpc({ n : I64 }, I64, Rpc.NoErr)
	nothere = Rpc.method("nothere")

	## 8h item 2 (checks/rpcerr.mjs): a method with two error tags, one with a payload and one with none. The callee gives
	## `Ok(2)` for n = 1, `Err(Busy("later"))` for n = 2 and `Err(StillOpen)` for other n. Three callees: the default
	## export, the entry point `Admin` and the class `Counter` (RpcErrRoutes.roc).
	busy : Rpc({ n : I64 }, I64, [Busy(Str), StillOpen])
	busy = Rpc.method("busy")

	## The same JS name with an argument type that the callee does not parse (`n` is a text): the caller gets `RpcErr`.
	busy_badarg : Rpc({ n : Str }, I64, [Busy(Str), StillOpen])
	busy_badarg = Rpc.method("busy")

	## A JS callee (`conformance/worker.js`) that gives the plain objects `{ Ok }` and `{ Err }` of the wire form.
	jsbusy : Rpc({ n : I64 }, I64, [Busy(Str), StillOpen])
	jsbusy = Rpc.method("jsbusy")

	## A JS callee that throws.
	jsthrow : Rpc({ n : I64 }, I64, Rpc.NoErr)
	jsthrow = Rpc.method("jsthrow")

	## A Roc callee that crashes.
	crashes : Rpc({ n : I64 }, I64, Rpc.NoErr)
	crashes = Rpc.method("crashes")

	## The callee has the error `[Surprise]`, the caller declares `Rpc.NoErr`: a reply `{"Err": "Surprise"}` is `BadData`.
	mismatch : Rpc({ n : I64 }, I64, [Surprise])
	mismatch = Rpc.method("mismatch")

	mismatch_caller : Rpc({ n : I64 }, I64, Rpc.NoErr)
	mismatch_caller = Rpc.method("mismatch")

	## The answer `{}` (examples/auction/REVIEW.md N1, research/rpc-unit-crash): the callee gives `Ok({})` for the lot "new"
	## and `Err(AlreadyOpen)` for others. Three callees: the default export, `Admin` and `Counter` (RpcErrRoutes.roc).
	open_lot : Rpc({ id : Str, close_ms : U64 }, {}, [AlreadyOpen])
	open_lot = Rpc.method("open_lot")

	## N5 G1a (checks/rpcerr.mjs, "infra"): the callee `?`s a platform error. The `err` has a domain tag and `Infra(Rpc.Infra)`:
	## the caller gets `Remote(NotOpen)` or `Remote(Infra(<tag>))`, and `Infra(RpcErr)` or `Infra(BadData)` when its own call failed.
	## `kind`: "domain", "crash" and, for the Durable Object `Store`: "sql", "constraint", "storage"; for the Workers: "d1".
	fail : Rpc({ kind : Str }, I64, [NotOpen, Infra(Rpc.Infra)])
	fail = Rpc.method("fail")

	## A JS callee (`conformance/worker.js`) that gives the plain objects of the wire form, with an infra tag in `Err`.
	jsfail : Rpc({ kind : Str }, I64, [NotOpen, Infra(Rpc.Infra)])
	jsfail = Rpc.method("jsfail")

	## `Rpc.forward` with `|e| e`: the callee calls `fail` and passes its errors on. The same `err` as `fail`.
	relay : Rpc({ kind : Str }, I64, [NotOpen, Infra(Rpc.Infra)])
	relay = Rpc.method("relay")

	## `Rpc.forward` with a domain mapping: the callee calls `fail` and maps `NotOpen` to `Shut`.
	relay_map : Rpc({ kind : Str }, I64, [Shut, Infra(Rpc.Infra)])
	relay_map = Rpc.method("relay_map")
}
