## RPC (MODULES.md 8): one constant names a method and its types. Both sides use it: the caller with `call!` on an
## `Object` or a `Service`, the callee with `on`. The argument and the reply cross as CBOR (MC5). The reply is one
## `Reply`: the `Ok` value or the `Err` tag of the method. A handler erases its types (CBOR in, CBOR out).
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Request
import Response
import cbor.Cbor

Rpc(arg, ret, err) :: { name : Str }.{

	## A constant (WR1): the method name and, by its annotation, the types of both sides. `err` is the tag union that
	## the callee can give (`Rpc.NoErr` for none): the caller gets it as `Remote(err)`.
	method : Str -> Rpc(arg, ret, err)
	method = |name| Rpc.{ name }

	## The method name: the JS method that Workers calls.
	name : Rpc(arg, ret, err) -> Str
	name = |m| m.name

	## The callee. `self` is `Object.Self` in a Durable Object (a Worker uses `on_worker`). The result of the
	## handler is the reply (`Reply`), also an `Err`. A tag that is not in `err` does not compile. An argument that
	## does not parse is a throw with the text `bad argument: <error>` (the caller gets `RpcErr`).
	on : Rpc(arg, ret, err), (self, arg => Try(ret, err)) -> Rpc.Handler(self) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on = |m, f!| {
		name: m.name,
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
	on_worker : Rpc(arg, ret, err), (arg => Try(ret, err)) -> Rpc.Handler({}) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on_worker = |m, f!| Rpc.on(m, |_, a| f!(a))

	## The bytes of a reply as the result of `call!`: an `Err` of the callee is `Remote(err)`, a reply that does not fit
	## is `BadData`.
	reply_of : List(U8) -> Try(ret, [BadData(Str), Remote(err)]) where [ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	reply_of = |bytes| {
		r : Try(Reply(ret, err), _)
		r = Cbor.parse(bytes)
		match r {
			Ok(Reply.Ok(v)) => Ok(v)
			Ok(Reply.Err(e)) => Err(Remote(e))
			Err(e) => Err(BadData(Str.inspect(e)))
		}
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
	Handler(self) : { name : Str, run! : self, List(U8) => Try(List(U8), Str) }

	## A named entry point (a `WorkerEntrypoint` class): `export const Admin = entrypointClass("Admin")` in the JS entry
	## file. A service binding with `entrypoint = "Admin"` reaches it. Its `fetch!` gets the requests of `Service.fetch!`
	## on that binding (the event `EntrypointFetch`). With no `fetch!`, the class has no `fetch` method in JS.
	entrypoint : Str, { fetch! ?: Request => Try(Response, e), rpc ?: List(Rpc.Handler({})) } -> Rpc.Entrypoint
	entrypoint = |ep_name, h| {
		name: ep_name,
		handlers: if (h.?fetch!.is_ok()) ["fetch"] else [],
		rpc: h.?rpc ?? [],
		fetch!: |req| match h.?fetch! {
			Ok(f!) => match f!(req) {
				Ok(res) => Respond(res)
				Err(e) => Failed(Str.inspect(e))
			}
			Err(MissingField) => Unhandled
		},
	}

	## An entry point with its types erased. `handlers`: the handlers that its JS class has (`fetch`), for the manifest.
	Entrypoint : { name : Str, handlers : List(Str), rpc : List(Rpc.Handler({})), fetch! : Request => [Respond(Response), Failed(Str), Unhandled] }
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
