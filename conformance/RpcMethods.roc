## The `Rpc` constants of the conformance app (MODULES.md 8): each names a method and its types for the caller and the
## callee. `ping` has two callees, the class `Counter` and the default export (`Worker.rpc`).
import pf.Rpc
import pf.Cbor
import pf.Io
import pf.Sql

RpcMethods :: [].{

	## The interfaces (typed namespaces, MODULES.md 7): `Counter` and `Store` are classes, `Default` is the default export
	## and `Admin` the entry point of this Worker. `NoRpc` is for the classes that have no Rpc method. A method that more
	## than one interface serves is a function of the interface value: `RpcMethods.ping(RpcMethods.counter_iface)`.
	Counter := []
	Store := []
	Default := []
	Admin := []
	NoRpc := []

	counter_iface : Rpc.Iface(RpcMethods.Counter)
	counter_iface = Rpc.iface("Counter")

	store_iface : Rpc.Iface(RpcMethods.Store)
	store_iface = Rpc.iface("Store")

	default_iface : Rpc.Iface(RpcMethods.Default)
	default_iface = Rpc.iface("Default")

	admin_iface : Rpc.Iface(RpcMethods.Admin)
	admin_iface = Rpc.iface("Admin")

	increment : Rpc(RpcMethods.Counter, { by : I64 }, I64, [Infra(Rpc.Infra)])
	increment = RpcMethods.counter_iface.method("increment")

	ping : Rpc.Iface(iface) -> Rpc(iface, { n : I64 }, Str, Rpc.NoErr)
	ping = |i| i.method("ping")

	## A method of `Counter` that waits `ms` before its reply (the deadline repro of `research/flake-foreign-sweep/`).
	nap : Rpc(RpcMethods.Counter, { ms : U64 }, U64, Rpc.NoErr)
	nap = RpcMethods.counter_iface.method("nap")

	## The callee gives `Err(Nope(n))`: the caller gets `Err(Remote(Nope(n)))`.
	boom : Rpc(RpcMethods.Counter, { n : I64 }, I64, [Nope(I64)])
	boom = RpcMethods.counter_iface.method("boom")

	## The reply is the argument: a `U64` of 2^60 comes back exact (CBOR, MC5).
	echo : Rpc(RpcMethods.Counter, { big : U64 }, { big : U64 }, Rpc.NoErr)
	echo = RpcMethods.counter_iface.method("echo")

	## A method of the named entry point `Admin`.
	purge : Rpc(RpcMethods.Admin, { prefix : Str }, Str, Rpc.NoErr)
	purge = RpcMethods.admin_iface.method("purge")

	## A JS method of `conformance/worker.js` (the default export): it gives the JS kinds of the fields of its argument.
	inspect : Rpc(RpcMethods.Default, { data : Cbor.Bytes, list : List(U8) }, { data : Str, list : Str }, Rpc.NoErr)
	inspect = RpcMethods.default_iface.method("inspect")

	## A JS method of `conformance/worker.js` that gives a text of `n` bytes (the RPC limit).
	big : Rpc(RpcMethods.Default, { n : U64 }, Str, Rpc.NoErr)
	big = RpcMethods.default_iface.method("big")

	## FO6 (PLAN.md 8f): a method whose argument type is `{}` takes a JS call with no argument (`stub.hello()`).
	hello : Rpc.Iface(iface) -> Rpc(iface, {}, Str, Rpc.NoErr)
	hello = |i| i.method("hello")

	## No callee has it.
	nothere : Rpc.Iface(iface) -> Rpc(iface, { n : I64 }, I64, Rpc.NoErr)
	nothere = |i| i.method("nothere")

	## 8h item 2 (checks/rpcerr.mjs): a method with two error tags, one with a payload and one with none. The callee gives
	## `Ok(2)` for n = 1, `Err(Busy("later"))` for n = 2 and `Err(StillOpen)` for other n. Three callees: the default
	## export, the entry point `Admin` and the class `Counter` (RpcErrRoutes.roc).
	busy : Rpc.Iface(iface) -> Rpc(iface, { n : I64 }, I64, [Busy(Str), StillOpen])
	busy = |i| i.method("busy")

	## The same JS name with an argument type that the callee does not parse (`n` is a text): the caller gets `RpcErr`.
	busy_badarg : Rpc.Iface(iface) -> Rpc(iface, { n : Str }, I64, [Busy(Str), StillOpen])
	busy_badarg = |i| i.method("busy")

	## A JS callee (`conformance/worker.js`) that gives the plain objects `{ Ok }` and `{ Err }` of the wire form.
	jsbusy : Rpc(RpcMethods.Default, { n : I64 }, I64, [Busy(Str), StillOpen])
	jsbusy = RpcMethods.default_iface.method("jsbusy")

	## A JS callee that throws.
	jsthrow : Rpc(RpcMethods.Default, { n : I64 }, I64, Rpc.NoErr)
	jsthrow = RpcMethods.default_iface.method("jsthrow")

	## A Roc callee that crashes.
	crashes : Rpc.Iface(iface) -> Rpc(iface, { n : I64 }, I64, Rpc.NoErr)
	crashes = |i| i.method("crashes")

	## The callee has the error `[Surprise]`, the caller declares `Rpc.NoErr`: a reply `{"Err": "Surprise"}` is `BadData`.
	mismatch : Rpc.Iface(iface) -> Rpc(iface, { n : I64 }, I64, [Surprise])
	mismatch = |i| i.method("mismatch")

	mismatch_caller : Rpc.Iface(iface) -> Rpc(iface, { n : I64 }, I64, Rpc.NoErr)
	mismatch_caller = |i| i.method("mismatch")

	## The answer `{}` (examples/auction/REVIEW.md N1, research/rpc-unit-crash): the callee gives `Ok({})` for the lot "new"
	## and `Err(AlreadyOpen)` for others. Three callees: the default export, `Admin` and `Counter` (RpcErrRoutes.roc).
	open_lot : Rpc.Iface(iface) -> Rpc(iface, { id : Str, close_ms : U64 }, {}, [AlreadyOpen])
	open_lot = |i| i.method("open_lot")

	## N5 G1a (checks/rpcerr.mjs, "infra"): the callee `?`s a platform error. The `err` has a domain tag and `Infra(Rpc.Infra)`:
	## the caller gets `Remote(NotOpen)` or `Remote(Infra(<tag>))`, and `Infra(RpcErr)` or `Infra(BadData)` when its own call failed.
	## A SQL constraint failure is the flat domain tag `Constraint` (MODULES.md 1, MC9): the caller gets `Remote(Constraint(..))`.
	## `kind`: "domain", "crash" and, for the Durable Object `Store`: "sql", "constraint", "storage"; for the Workers: "d1".
	fail : Rpc.Iface(iface) -> Rpc(iface, { kind : Str }, I64, [NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
	fail = |i| i.method("fail")

	## A JS callee (`conformance/worker.js`) that gives the plain objects of the wire form, with an infra tag in `Err`.
	jsfail : Rpc(RpcMethods.Default, { kind : Str }, I64, [NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
	jsfail = RpcMethods.default_iface.method("jsfail")

	## `Rpc.forward` with `|e| e`: the callee calls `fail` and passes its errors on. The same `err` as `fail`.
	relay : Rpc.Iface(iface) -> Rpc(iface, { kind : Str }, I64, [NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
	relay = |i| i.method("relay")

	## `Rpc.forward` with a domain mapping: the callee calls `fail` and maps `NotOpen` to `Shut`.
	relay_map : Rpc.Iface(iface) -> Rpc(iface, { kind : Str }, I64, [Shut, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
	relay_map = |i| i.method("relay_map")
}
