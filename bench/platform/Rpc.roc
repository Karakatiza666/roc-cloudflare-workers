## RPC (MODULES.md 8): one constant names a method and its types. Both sides use it: the caller with `call!` on an
## `Object` or a `Service`, the callee with `on`. The argument and the reply cross as CBOR (MC5). A handler erases its
## types (CBOR in, CBOR out) and turns an `Err` into text, so each handler can have its own error type.
import Request
import Response
import cbor.Cbor

Rpc(arg, ret) :: { name : Str }.{
	## A constant (WR1): the method name and, by its annotation, the types of both sides.
	method : Str -> Rpc(arg, ret)
	method = |name| Rpc.{ name }

	## The method name: the JS method that Workers calls.
	name : Rpc(arg, ret) -> Str
	name = |m| m.name

	## The callee. `self` is `Object.Self` in a Durable Object and `{}` in a Worker entry point. An `Err(e)` of the
	## handler is a throw with the text `Str.inspect(e)` (the caller gets `RpcErr`), an argument that does not parse
	## is a throw with the text `bad argument: <error>`.
	on : Rpc(arg, ret), (self, arg => Try(ret, e)) -> Rpc.Handler(self) where [arg.Cbor.Parseable([InvalidCbor(U64), ..errs]), ret.Cbor.Encodable([])]
	on = |m, f!| {
		name: m.name,
		run!: |self, bytes| match Cbor.parse(bytes) {
			Ok(a) => match f!(self, a) {
				Ok(r) => Ok(Cbor.encode(r))
				Err(e) => Err(Str.inspect(e))
			}
			Err(e) => Err("bad argument: ${Str.inspect(e)}")
		},
	}

	## A method with its types erased: the argument as CBOR in, the reply as CBOR out, an error as text.
	Handler(self) : { name : Str, run! : self, List(U8) => Try(List(U8), Str) }

	## A named entry point (a `WorkerEntrypoint` class): `export const Admin = entrypointClass("Admin")` in the JS entry
	## file. A service binding with `entrypoint = "Admin"` reaches it. Its `fetch!` gets the requests of `Service.fetch!`
	## on that binding (the event `EntrypointFetch`). With no `fetch!`, the class has no `fetch` method in JS.
	entrypoint : Str, { fetch! ?: Request => Try(Response, e), rpc ?: List(Rpc.Handler({})) } -> Rpc.Entrypoint
	entrypoint = |ep_name, h| {
		name: ep_name,
		handlers: if h.?fetch!.is_ok() ["fetch"] else [],
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
