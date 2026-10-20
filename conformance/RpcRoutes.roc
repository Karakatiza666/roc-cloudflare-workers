## RPC (MODULES.md 8, PLAN.md 8f part 1): the methods of the default export (`rpc` of `Worker`), the named entry point
## `Admin` (`entrypoints`), and the routes that call them through the service bindings of `checks/rpc.mjs`: `SELF` (the
## default export of this Worker) and `ADMIN` (the entry point `Admin` of this Worker).
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service
import pf.Io
import pf.Cbor
import RpcMethods
import RpcErrRoutes

self_service = Service.binding("SELF")

admin_service = Service.binding("ADMIN")

RpcRoutes :: [].{

	## The RPC methods of the default export.
	rpc : List(Rpc.Handler({}))
	rpc = [RpcMethods.ping.on_worker(default_ping!), RpcMethods.hello.on_worker(default_hello!)].concat(RpcErrRoutes.service_handlers)

	## The named entry points.
	entrypoints : List(Rpc.Entrypoint)
	entrypoints = [Rpc.entrypoint("Admin", { fetch!: admin_fetch!, rpc: [RpcMethods.purge.on_worker(purge!)].concat(RpcErrRoutes.service_handlers) })]

	route! : Request, List(Str) => Response
	route! = |_req, path| match path {
		# One `Rpc` constant calls a method of an object (`/objects/rpc/ping`) and of a service (here).
		["ping"] => show(self_service.call!(RpcMethods.ping, { n: 5 }))
		["ping_io"] => show(Io.run!(self_service.call(RpcMethods.ping, { n: 6 })))
		["nothere"] => show(self_service.call!(RpcMethods.nothere, { n: 1 }))
		# `Service.fetch!` on a binding with `entrypoint = "Admin"` reaches the `fetch!` of `Admin`.
		["admin_fetch"] => match admin_service.fetch!(Request.get("http://x/hello")) {
			Ok(res) => Response.from_text(200, "${res.status().to_str()} ${res.text!() ?? "?"}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		["admin_fetch_io"] => match Io.run!(admin_service.fetch(Request.get("http://x/hello"))) {
			Ok(res) => Response.from_text(200, "${res.status().to_str()} ${res.text!() ?? "?"}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		["admin_call"] => show(admin_service.call!(RpcMethods.purge, { prefix: "v1/" }))
		# MC5: a `Cbor.Bytes` field reaches a JS callee as a `Uint8Array`, a `List(U8)` field as an `Array`.
		["inspect"] => show(self_service.call!(RpcMethods.inspect, { data: Cbor.bytes([1, 2, 3]), list: [1, 2, 3] }))
		# The RPC limit: a reply above 32 MiB is `RpcErr`.
		["big"] => match self_service.call!(RpcMethods.big, { n: 33_554_433 }) {
			Ok(s) => Response.from_text(200, "Ok ${s.count_utf8_bytes().to_str()}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		["small"] => match self_service.call!(RpcMethods.big, { n: 1_000 }) {
			Ok(s) => Response.from_text(200, "Ok ${s.count_utf8_bytes().to_str()}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		_ => Response.from_text(404, "no route")
	}
}

show = |r| Response.from_text(200, Str.inspect(r))

default_ping! : { n : I64 } => Try(Str, Rpc.NoErr)
default_ping! = |{ n }| Ok("default ping ${n.to_str()}")

default_hello! : {} => Try(Str, Rpc.NoErr)
default_hello! = |{}| Ok("default hello")

admin_fetch! : Request => Try(Response, [])
admin_fetch! = |req| Ok(Response.from_text(200, "admin fetch ${req.url()}"))

purge! : { prefix : Str } => Try(Str, Rpc.NoErr)
purge! = |{ prefix }| Ok("purged ${prefix}")
