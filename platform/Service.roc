## A service binding (MODULES.md 8): `env[name]`, plain data (MC1). `fetch!` sends a request to the bound Worker (or to
## its named entry point, `entrypoint = "Admin"` in the Wrangler config). `call!` calls an RPC method with an `Rpc`
## constant. Each is one program and one wait.
import Io
import Request
import Response
import Rpc
import Remote
import cbor.Cbor

Service(iface) :: { name : Str, service : Str, entrypoint : Str, iface_name : Str }.{

	## The binding `name`, with the interface of the Worker that it reaches (`Rpc.Iface`): `call!` takes the `Rpc`
	## constants of that interface only.
	binding : Str, Rpc.Iface(iface) -> Service(iface)
	binding = |name, iface| Service.{ name, service: "", entrypoint: "", iface_name: iface.name() }

	## `service`: the name of the bound Worker. `entrypoint`: its named entry point. Both are for the manifest only
	## (`declare`): the calls use the binding as Workers made it.
	binding_with : Str, Rpc.Iface(iface), { service ?: Str, entrypoint ?: Str } -> Service(iface)
	binding_with = |name, iface, opts| Service.{ name, service: opts.?service ?? "", entrypoint: opts.?entrypoint ?? "", iface_name: iface.name() }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `service`, with
	## `service` and `entrypoint` when `binding_with` gave them, and `iface`, the name of its interface.
	declare : Service(iface) -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |s| {
		props = [("service", s.service), ("entrypoint", s.entrypoint), ("iface", s.iface_name)].keep_if(|(_, v)| v != "")
		{ name: s.name, kind: "service", props }
	}

	## `env[name].fetch(request)`. The response body stays a stream.
	fetch : Service(iface), Request -> Io(Response, [Infra([ServiceErr(Io.Thrown)])])
	fetch = |s, req| Remote.fetch([Get(Root("env"), s.name)], 0, req, |t| Infra(ServiceErr(t)))

	fetch! : Service(iface), Request => Try(Response, [Infra([ServiceErr(Io.Thrown)])])
	fetch! = |s, req| Io.run!(fetch(s, req))

	## `env[name][method](arg)`: the reply is read to the RPC limit of Workers (32 MiB). An `Err` of the callee is
	## `Remote(err)`.
	call : Service(iface), Rpc(iface, arg, ret, err), arg -> Io(ret, [Remote(err), Infra([RpcErr(Io.Thrown), BadData(Str)])]) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	call = |s, m, a| Remote.call([Get(Root("env"), s.name)], 0, m, a, Remote.rpc_max)

	call! : Service(iface), Rpc(iface, arg, ret, err), arg => Try(ret, [Remote(err), Infra([RpcErr(Io.Thrown), BadData(Str)])]) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	call! = |s, m, a| Io.run!(call(s, m, a))
}
