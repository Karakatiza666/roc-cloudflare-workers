## Typed RPC errors (MODULES.md 8, PLAN.md 8h item 2): callees with the error `[Busy(Str), StillOpen]`, and the routes that
## call them through a default entry point (`self`), a named entry point (`admin`) and a Durable Object (`obj`).
## `/rpcerr/<target>/<case>?n=<n>`. The text of a route is the exact tag that the caller matched.
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service
import pf.Object
import pf.Io
import RpcMethods
import Q

self_service = Service.binding("SELF")
admin_service = Service.binding("ADMIN")
counters = Object.namespace("COUNTERS", { class: "Counter" })

RpcErrRoutes :: [].{

	## The callees of the default export and of `Admin`.
	service_handlers : List(Rpc.Handler({}))
	service_handlers = [RpcMethods.busy.on(busy!), RpcMethods.crashes.on(crashes!), RpcMethods.mismatch.on(mismatch!)]

	## The callees of the class `Counter`.
	object_handlers : List(Rpc.Handler(Object.Self))
	object_handlers = [RpcMethods.busy.on(busy!), RpcMethods.crashes.on(crashes!), RpcMethods.mismatch.on(mismatch!)]

	route! : Request, List(Str) => Response
	route! = |req, path| {
		n = Q.num(req, "n").to_i64_try() ?? 0
		text = match path {
			["self", "jsbusy"] => busy_text(self_service.call!(RpcMethods.jsbusy, { n: n }))
			["self", "jsthrow"] => noerr_text(self_service.call!(RpcMethods.jsthrow, { n: n }))
			["self", case] => by_service!(self_service, case, n)
			["admin", case] => by_service!(admin_service, case, n)
			["obj", case] => by_object!(counters.named(Q.text(req, "name")), case, n)
			_ => "no route"
		}
		Response.from_text(200, text)
	}
}

by_service! : Service, Str, I64 => Str
by_service! = |s, case, n| match case {
	"busy" => busy_text(s.call!(RpcMethods.busy, { n: n }))
	"badarg" => busy_text(s.call!(RpcMethods.busy_badarg, { n: "x" }))
	"crash" => noerr_text(s.call!(RpcMethods.crashes, { n: n }))
	"stray" => noerr_text(s.call!(RpcMethods.mismatch_caller, { n: n }))
	_ => "no case"
}

by_object! : Object, Str, I64 => Str
by_object! = |o, case, n| match case {
	"busy" => busy_text(o.call!(RpcMethods.busy, { n: n }))
	"badarg" => busy_text(o.call!(RpcMethods.busy_badarg, { n: "x" }))
	"crash" => noerr_text(o.call!(RpcMethods.crashes, { n: n }))
	"stray" => noerr_text(o.call!(RpcMethods.mismatch_caller, { n: n }))
	_ => "no case"
}

# The caller matches each tag of the error by its name: a wrong tag does not compile.
busy_text : Try(I64, [RpcErr(Io.Thrown), BadData(Str), Remote([Busy(Str), StillOpen])]) -> Str
busy_text = |r| match r {
	Ok(v) => "Ok ${v.to_str()}"
	Err(Remote(Busy(s))) => "Busy ${s}"
	Err(Remote(StillOpen)) => "StillOpen"
	Err(RpcErr(t)) => "RpcErr ${t.message}"
	Err(BadData(_)) => "BadData"
}

noerr_text : Try(I64, [RpcErr(Io.Thrown), BadData(Str), Remote(Rpc.NoErr)]) -> Str
noerr_text = |r| match r {
	Ok(v) => "Ok ${v.to_str()}"
	Err(RpcErr(t)) => "RpcErr ${t.message}"
	Err(BadData(_)) => "BadData"
}

busy! : self, { n : I64 } => Try(I64, [Busy(Str), StillOpen])
busy! = |_self, { n }| match n {
	1 => Ok(2)
	2 => Err(Busy("later"))
	_ => Err(StillOpen)
}

crashes! : self, { n : I64 } => Try(I64, Rpc.NoErr)
crashes! = |_self, { n }| if n >= 0 crash "rpc callee crash" else Ok(n)

mismatch! : self, { n : I64 } => Try(I64, [Surprise])
mismatch! = |_self, { n }| if n >= 0 Err(Surprise) else Ok(n)
