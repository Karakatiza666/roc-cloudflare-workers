## RPC (MODULES.md 8): one constant names a method and its types. Both sides use it: the caller with `call!` on an
## `Object` or a `Service`, the callee with `on`. The argument and the reply cross as CBOR (MC5). The reply is
## `{"Ok": value}` or `{"Err": tag}` of the method (`ok_head`). A handler erases its types (CBOR in, CBOR out).
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
	## handler is the reply (`ok_head`), also an `Err`. A tag that is not in `err` does not compile. An argument that
	## does not parse is a throw with the text `bad argument: <error>` (the caller gets `RpcErr`).
	on : Rpc(arg, ret, err), (self, arg => Try(ret, err)) -> Rpc.Handler(self) where [arg.Cbor.Parseable([InvalidCbor(U64), ..errs]), ret.Cbor.Encodable([]), err.Cbor.Encodable([])]
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
	on_worker : Rpc(arg, ret, err), (arg => Try(ret, err)) -> Rpc.Handler({}) where [arg.Cbor.Parseable([InvalidCbor(U64), ..errs]), ret.Cbor.Encodable([]), err.Cbor.Encodable([])]
	on_worker = |m, f!| Rpc.on(m, |_, a| f!(a))

	## The bytes of a reply as the result of `call!`: an `Err` of the callee is `Remote(err)`, a reply that does not fit
	## is `BadData`. It reads the head by hand (`ok_head`) and parses only the value: the derived parser of a tag with a
	## `{}` value crashes the compiler (research/rpc-unit-crash).
	reply_of : List(U8) -> Try(ret, [BadData(Str), Remote(err)]) where [ret.Cbor.Parseable([InvalidCbor(U64), ..e1]), err.Cbor.Parseable([InvalidCbor(U64), ..e2])]
	reply_of = |bytes| {
		if bytes.starts_with(ok_head) {
			v : Try(ret, _)
			v = Cbor.parse(bytes.drop_first(ok_head.len()))
			match v {
				Ok(r) => Ok(r)
				Err(e) => Err(BadData(Str.inspect(e)))
			}
		} else if bytes.starts_with(err_head) {
			v : Try(err, _)
			v = Cbor.parse(bytes.drop_first(err_head.len()))
			match v {
				Ok(e) => Err(Remote(e))
				Err(e) => Err(BadData(Str.inspect(e)))
			}
		} else {
			Err(BadData("not a reply: ${Str.inspect(bytes.take_first(8))}"))
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

	## A method with its types erased: the argument as CBOR in, the reply (`ok_head`) as CBOR out. `Err`: an argument
	## that does not parse, as text.
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

## The reply of a method on the wire: `{"Ok": value}` or `{"Err": tag}` (the derived CBOR of a tag `Ok(ret)` or
## `Err(err)`). A JS callee gives the same shape. These are its first bytes: a map of one entry and its key. `on` writes
## them and `reply_of` reads them by hand, as the derived codec of the tag crashes the compiler: the encoder in a type
## module of the app (research/e1-errors/mod), the parser with a `{}` value (research/rpc-unit-crash). The bytes:
## research/rpc-err-sql-params/enc.roc.
ok_head : List(U8)
ok_head = [0xa1, 0x62, 0x4f, 0x6b]

err_head : List(U8)
err_head = [0xa1, 0x63, 0x45, 0x72, 0x72]
