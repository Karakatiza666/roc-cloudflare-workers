## A service binding (MODULES.md 8): `env[name]`, plain data (MC1). `fetch!` sends a request to the bound Worker (or to
## its named entry point, `entrypoint = "Admin"` in the Wrangler config). `call!` calls an RPC method with an `Rpc`
## constant. Each is one program and one wait.
import Io
import Request
import Response
import Rpc
import Remote
import cbor.Cbor

Service :: { name : Str }.{
	binding : Str -> Service
	binding = |name| Service.{ name }

	## `env[name].fetch(request)`. The response body stays a stream.
	fetch : Service, Request -> Io(Response, [ServiceErr(Io.Thrown)])
	fetch = |s, req| Remote.fetch([Get(Root("env"), s.name)], 0, req, |t| ServiceErr(t))

	fetch! : Service, Request => Try(Response, [ServiceErr(Io.Thrown)])
	fetch! = |s, req| Io.run!(fetch(s, req))

	## `env[name][method](arg)`: the reply is read to the RPC limit of Workers (32 MiB). An `Err` of the callee is
	## `Remote(err)`.
	call : Service, Rpc(arg, ret, err), arg -> Io(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err)]) where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..e1]), err.Cbor.Parseable([InvalidCbor(U64), ..e2])]
	call = |s, m, a| Remote.call([Get(Root("env"), s.name)], 0, m, a, Remote.rpc_max)

	call! : Service, Rpc(arg, ret, err), arg => Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err)]) where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..e1]), err.Cbor.Parseable([InvalidCbor(U64), ..e2])]
	call! = |s, m, a| Io.run!(call(s, m, a))
}
