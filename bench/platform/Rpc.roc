## RPC (MODULES.md 8): one constant names a method and its types. Both sides use it: the caller with `call!` on an
## `Object` or a `Service`, the callee with `on`. The argument and the reply cross as CBOR (MC5). The reply is one
## `Reply`: the `Ok` value or the `Err` tag of the method. A handler erases its types (CBOR in, CBOR out).
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Io
import Request
import Response
import Sql
import cbor.Cbor

Rpc(iface, arg, ret, err) :: { name : Str, iface_name : Str }.{

	## The method name: the JS method that Workers calls.
	name : Rpc(iface, arg, ret, err) -> Str
	name = |m| m.name

	## The name of the interface of the method (`Rpc.iface("Ledger")`): the manifest records it, and `roc-cloudflare-workers sync`
	## compares it across Workers.
	iface_name : Rpc(iface, arg, ret, err) -> Str
	iface_name = |m| m.iface_name

	## The callee. `self` is `Object.Self` in a Durable Object (a Worker uses `on_worker`). A class takes a list of
	## `Rpc.Serves` of one `iface`. The result of the handler is the reply (`Reply`), also an `Err`. A tag that is not in `err` does not compile. An argument that
	## does not parse is a throw with the text `bad argument: <error>` (the caller gets `RpcErr`).
	on : Rpc(iface, arg, ret, err), (self, arg => Try(ret, err)) -> Rpc.Serves(iface, self) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on = |m, f!| Rpc.Serves.{
		name: m.name,
		iface_name: m.iface_name,
		run!: |self, bytes| match Cbor.parse(bytes) {
			Ok(a) => match f!(self, a) {
				Ok(r) => Ok(ok_head.concat(Cbor.encode(r)))
				Err(e) => Ok(err_head.concat(Cbor.encode(e)))
			}
			Err(e) => Err("bad argument: ${Str.inspect(e)}")
		},
	}

	## The callee in a Worker (the `rpc` of `Worker.new` and of `Rpc.entrypoint`): `on` with no `self`, as a Worker
	## entry point has none.
	on_worker : Rpc(iface, arg, ret, err), (arg => Try(ret, err)) -> Rpc.Serves(iface, {}) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on_worker = |m, f!| Rpc.on(m, |_, a| f!(a))

	## The bytes of a reply as the result of `call!`: an `Err` of the callee is `Remote(err)`, a reply that does not fit
	## is `Infra(BadData)`.
	reply_of : List(U8) -> Try(ret, [Infra([BadData(Str)]), Remote(err)]) where [ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	reply_of = |bytes| {
		r : Try(Reply(ret, err), _)
		r = Cbor.parse(bytes)
		match r {
			Ok(Reply.Ok(v)) => Ok(v)
			Ok(Reply.Err(e)) => Err(Remote(e))
			Err(e) => Err(Infra(BadData(Str.inspect(e))))
		}
	}

	## The infrastructure errors of the platform, one closed union (MODULES.md 1, MC9). Each platform function gives
	## its own tags in `Infra(...)`. The `err` of a method closes them: `[NotOpen, Infra(Rpc.Infra)]`.
	Infra : [
		StorageErr(Io.Thrown),
		SqlErr(Io.Thrown),
		Constraint(Sql.Constraint),
		D1Err(Io.Thrown),
		KvErr(Io.Thrown),
		R2Err(Io.Thrown),
		CacheErr(Io.Thrown),
		QueueErr(Io.Thrown),
		ObjectErr(Io.Thrown),
		ServiceErr(Io.Thrown),
		RpcErr(Io.Thrown),
		HttpErr(Io.Thrown),
		Network(Io.Thrown),
		SocketErr(Io.Thrown),
		BodyErr(Io.Thrown),
		CryptoErr(Io.Thrown),
		AiErr(Io.Thrown),
		VectorizeErr(Io.Thrown),
		WorkflowsErr(Io.Thrown),
		EmailErr(Io.Thrown),
		AnalyticsErr(Io.Thrown),
		AssetsErr(Io.Thrown),
		SecretsStoreErr(Io.Thrown),
		LimitErr(Io.Thrown),
		BadData(Str),
		InvalidJson(Str),
		MissingEnv(Str),
		TooLarge,
		TimedOut,
	]

	## A nested call in a handler, for `?`: `call!(...) ? Rpc.forward(f)`. The errors of this call stay in `Infra`,
	## `f` maps the `err` of the callee (`Rpc.forward(|e| e)` when the two methods have one error type).
	forward : (err -> [Infra(Rpc.Infra), ..e]) -> ([Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote(err)] -> [Infra(Rpc.Infra), ..e])
	forward = |f| |x| match x {
		Infra(RpcErr(t)) => Infra(RpcErr(t))
		Infra(BadData(s)) => Infra(BadData(s))
		Remote(e) => f(e)
	}

	## The `err` of a method with no errors. It has no values. `[]` has no derived codec, so this type has its own: it
	## writes nothing (it has no values), and a reply `{"Err": ...}` does not parse (`BadData`).
	NoErr := [].{
		parser_for : Cbor -> (Cbor.State -> Try({ value : Rpc.NoErr, rest : Cbor.State }, [InvalidCbor(U64)]))
		parser_for = |_| |_state| Err(InvalidCbor(0))

		encoder_for : Cbor -> (Rpc.NoErr, List(U8) -> Try(List(U8), []))
		encoder_for = |_| |_v, out| Ok(out)
	}

	## A method with its types erased: the argument as CBOR in, the reply (`Reply`) as CBOR out. `Err`: an argument
	## that does not parse, as text.
	Handler(self) : { name : Str, iface_name : Str, run! : self, List(U8) => Try(List(U8), Str) }

	## A handler of a method of the interface `iface`. A class, an entry point and a Worker take a list of them, so all
	## their methods have one interface.
	Serves(iface, self) := { name : Str, iface_name : Str, run! : self, List(U8) => Try(List(U8), Str) }.{

		## The handler with its interface erased.
		erase : Rpc.Serves(iface, self) -> Rpc.Handler(self)
		erase = |h| { name: h.name, iface_name: h.iface_name, run!: h.run! }
	}

	## An interface (MODULES.md 8): a type of the app with no values (`Ledger := []`) and its name as text. The shared module
	## of the Workers makes one value for each interface (`ledger : Rpc.Iface(Ledger)`, `ledger = Rpc.iface("Ledger")`).
	## The type connects the two sides of a call in the compiler. The name goes to the manifest: the type cannot cross a
	## Worker (the link of a service binding or of a `namespace_remote` is in the Wrangler config), so `roc-cloudflare-workers
	## sync` compares the names of the Workers of one repo. A call with no `Iface`, or with the `Iface` of another interface,
	## does not compile.
	Iface(iface) := { name : Str }.{

		## A method of the interface (WR1): the method name and, by the annotation of the constant, the types of both sides.
		## `err` is the tag union that the callee can give (`Rpc.NoErr` for none): the caller gets it as `Remote(err)`.
		## A method that two interfaces serve is a function of the interface: `ping : Rpc.Iface(iface) -> Rpc(iface, {}, Str, Rpc.NoErr)`,
		## `ping = |i| i.method("ping")`.
		method : Rpc.Iface(iface), Str -> Rpc(iface, arg, ret, err)
		method = |i, method_name| Rpc.{ name: method_name, iface_name: i.name }

		## The name that `Rpc.iface` got.
		name : Rpc.Iface(iface) -> Str
		name = |i| i.name
	}

	## The value of an interface: `ledger = Rpc.iface("Ledger")`. The name is the name of the type, as text. Two values with
	## the same name and different types are two interfaces for the compiler and one for `sync`.
	iface : Str -> Rpc.Iface(iface)
	iface = |iface_text| Rpc.Iface.{ name: iface_text }

	## The distinct interface names of some handlers, in order: none for no handler. A class, a Worker and an entry point
	## have one name at most: two names are an error at load (`checkManifest` in `js/manifest.js`).
	iface_names : List(Rpc.Handler(self)) -> List(Str)
	iface_names = |hs| hs.fold([], |acc, h| if (acc.contains(h.iface_name)) acc else acc.append(h.iface_name))

	## A named entry point (a `WorkerEntrypoint` class): `export const Admin = entrypointClass("Admin")` in the JS entry
	## file. A service binding with `entrypoint = "Admin"` reaches it. Its `fetch!` gets the requests of `Service.fetch!`
	## on that binding (the event `EntrypointFetch`). With no `fetch!`, the class has no `fetch` method in JS.
	entrypoint : Str, { fetch! ?: Request => Try(Response, e), rpc ?: List(Rpc.Serves(iface, {})) } -> Rpc.Entrypoint
	entrypoint = |ep_name, h| {
		name: ep_name,
		handlers: if (h.?fetch!.is_ok()) ["fetch"] else [],
		rpc: (h.?rpc ?? []).map(|m| m.erase()),
		iface_names: Rpc.iface_names((h.?rpc ?? []).map(|m| m.erase())),
		fetch!: |req| match h.?fetch! {
			Ok(f!) => match f!(req) {
				Ok(res) => Respond(res)
				Err(e) => Failed(Str.inspect(e))
			}
			Err(MissingField) => Unhandled
		},
	}

	## An entry point with its types erased. `handlers`: the handlers that its JS class has (`fetch`), for the manifest.
	Entrypoint : { name : Str, handlers : List(Str), rpc : List(Rpc.Handler({})), iface_names : List(Str), fetch! : Request => [Respond(Response), Failed(Str), Unhandled] }
}

## The reply of a method on the wire: `{"Ok": value}` or `{"Err": tag}` (the derived CBOR of a tag). A JS callee gives
## the same shape. `Try` has no codec, so the wire form is its own type. `reply_of` parses it, `on` writes its bytes.
Reply(ret, err) := [Ok(ret), Err(err)].{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## The first bytes of a reply: a map of one entry and its key, "Ok" or "Err" (the bytes that the derived encoder of
## `Reply` gives). `on` writes them by hand: `Cbor.encode(Reply.Ok(r))` in `on` crashes the compiler when a type module
## of the app uses `on` (research/e1-errors/mod). The bytes: research/rpc-err-sql-params/enc.roc.
ok_head : List(U8)
ok_head = [0xa1, 0x62, 0x4f, 0x6b]

err_head : List(U8)
err_head = [0xa1, 0x63, 0x45, 0x72, 0x72]
