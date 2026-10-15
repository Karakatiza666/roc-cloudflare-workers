import Io
import Cbor

## One constant names an RPC method and its types. Both sides use it: the caller with `call`, the callee with `on`.
Rpc(arg, ret) :: { name : Str }.{
	method : Str -> Rpc(arg, ret)
	method = |name| Rpc.{ name }

	## Caller side. `target` is the start of the program: a Durable Object stub or a service binding.
	call : Rpc(arg, ret), List(Str), arg -> Io(ret, [RpcErr(Io.Thrown), BadData(Str)])
		where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	call = |m, target, arg| {
		Rpc.{ name } = m
		Io.typed(["rpc"].concat(target).concat([name, Io.arg(arg)]), |t| RpcErr(t))
	}

	## Callee side. `self` is the object (`Object.Self`) or `{}` for a Worker entry point.
	on : Rpc(arg, ret), (self, arg => Try(ret, e)) -> Rpc.Handler(self)
		where [arg.Cbor.Parseable([InvalidCbor(U64), ..errs]), ret.Cbor.Encodable([])]
	on = |m, f!| {
		Rpc.{ name } = m
		{
			name,
			run!: |self, bytes| match Cbor.parse(bytes) {
				Ok(arg) => f!(self, arg).map_ok(|r| Cbor.encode(r)).map_err(|e| Str.inspect(e))
				Err(e) => Err("bad argument: ${Str.inspect(e)}")
			},
		}
	}

	## A typed method with its types erased: CBOR in and out. JS gives the callee the argument
	## as packed CBOR, and turns the reply into a JS value for the caller.
	Handler(self) : { name : Str, run! : self, List(U8) => Try(List(U8), Str) }

	serve! : List(Rpc.Handler(self)), self, Str, List(U8) => Try(List(U8), Str)
	serve! = |handlers, self, name, bytes| match handlers.find_first(|h| h.name == name) {
		Ok(h) => {
			run! = h.run!
			run!(self, bytes)
		}
		Err(_) => Err("no method ${name}")
	}
}
