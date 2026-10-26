## Typed RPC errors (MODULES.md 8, PLAN.md 8h item 2): callees with the error `[Busy(Str), StillOpen]`, and the routes that
## call them through a default entry point (`self`), a named entry point (`admin`) and a Durable Object (`obj`).
## `/rpcerr/<target>/<case>?n=<n>`. The text of a route is the exact tag that the caller matched.
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service
import pf.Object
import pf.Io
import pf.D1
import pf.Sql
import RpcMethods
import Q

self_service = Service.binding("SELF", RpcMethods.default_iface)

admin_service = Service.binding("ADMIN", RpcMethods.admin_iface)

db = D1.binding("DB")

RpcErrRoutes :: [].{

	## The callees of the default export and of `Admin`.
	service_handlers : Rpc.Iface(iface) -> List(Rpc.Serves(iface, {}))
	service_handlers = |i| [RpcMethods.busy(i).on(busy!), RpcMethods.crashes(i).on(crashes!), RpcMethods.mismatch(i).on(mismatch!), RpcMethods.open_lot(i).on(open_lot!), RpcMethods.fail(i).on(fail_svc!), RpcMethods.relay(i).on(relay_svc!), RpcMethods.relay_map(i).on(relay_map_svc!)]

	## The callees of the class `Counter`.
	object_handlers : List(Rpc.Serves(RpcMethods.Counter, Object.Self))
	object_handlers = [RpcMethods.busy(RpcMethods.counter_iface).on(busy!), RpcMethods.crashes(RpcMethods.counter_iface).on(crashes!), RpcMethods.mismatch(RpcMethods.counter_iface).on(mismatch!), RpcMethods.open_lot(RpcMethods.counter_iface).on(open_lot!)]

	## `counters` and `stores` are the namespaces of `ObjectRoutes` (the class `Counter` has the handlers of this module, so this module cannot import it).
	route! : Object.Namespace(RpcMethods.Counter), Object.Namespace(RpcMethods.Store), Request, List(Str) => Response
	route! = |counters, stores, req, path| {
		n = Q.num(req, "n").to_i64_try() ?? 0
		kind = { kind: Q.text(req, "kind") }
		text = match path {
			# N5 G1a: `Infra` errors of a callee. `fail`: the callee `?`s a platform error (the Durable Object `Store`, or the Workers).
			# `relay` and `relay_map`: the callee calls `fail` and passes its errors on with `Rpc.forward`.
			["store", "fail"] => fail_text(stores.named(Q.text(req, "name")).call!(RpcMethods.fail(RpcMethods.store_iface), kind))
			["self", "fail"] => fail_text(self_service.call!(RpcMethods.fail(RpcMethods.default_iface), kind))
			["admin", "fail"] => fail_text(admin_service.call!(RpcMethods.fail(RpcMethods.admin_iface), kind))
			["self", "jsfail"] => fail_text(self_service.call!(RpcMethods.jsfail, kind))
			["self", "relay"] => fail_text(self_service.call!(RpcMethods.relay(RpcMethods.default_iface), kind))
			["admin", "relay"] => fail_text(admin_service.call!(RpcMethods.relay(RpcMethods.admin_iface), kind))
			["obj", "relay"] => fail_text(counters.named(Q.text(req, "name")).call!(RpcMethods.relay(RpcMethods.counter_iface), kind))
			["self", "relay_map"] => map_text(self_service.call!(RpcMethods.relay_map(RpcMethods.default_iface), kind))
			["admin", "relay_map"] => map_text(admin_service.call!(RpcMethods.relay_map(RpcMethods.admin_iface), kind))
			["obj", "relay_map"] => map_text(counters.named(Q.text(req, "name")).call!(RpcMethods.relay_map(RpcMethods.counter_iface), kind))
			["self", "jsbusy"] => busy_text(self_service.call!(RpcMethods.jsbusy, { n: n }))
			["self", "jsthrow"] => noerr_text(self_service.call!(RpcMethods.jsthrow, { n: n }))
			["self", case] => by_service!(self_service, RpcMethods.default_iface, case, n)
			["admin", case] => by_service!(admin_service, RpcMethods.admin_iface, case, n)
			["obj", case] => by_object!(counters.named(Q.text(req, "name")), RpcMethods.counter_iface, case, n)
			_ => "no route"
		}
		Response.from_text(200, text)
	}
}

by_service! : Service(iface), Rpc.Iface(iface), Str, I64 => Str
by_service! = |s, i, case, n| match case {
	"busy" => busy_text(s.call!(RpcMethods.busy(i), { n: n }))
	"badarg" => busy_text(s.call!(RpcMethods.busy_badarg(i), { n: "x" }))
	"crash" => noerr_text(s.call!(RpcMethods.crashes(i), { n: n }))
	"stray" => noerr_text(s.call!(RpcMethods.mismatch_caller(i), { n: n }))
	"unit" => unit_text(s.call!(RpcMethods.open_lot(i), lot(n)))
	_ => "no case"
}

by_object! : Object(iface), Rpc.Iface(iface), Str, I64 => Str
by_object! = |o, i, case, n| match case {
	"busy" => busy_text(o.call!(RpcMethods.busy(i), { n: n }))
	"badarg" => busy_text(o.call!(RpcMethods.busy_badarg(i), { n: "x" }))
	"crash" => noerr_text(o.call!(RpcMethods.crashes(i), { n: n }))
	"stray" => noerr_text(o.call!(RpcMethods.mismatch_caller(i), { n: n }))
	"unit" => unit_text(o.call!(RpcMethods.open_lot(i), lot(n)))
	# The shape of examples/auction (REVIEW.md N1): `?` on a `call!` with the answer `{}`.
	"unit_try" => unit_try_text(open_room!(o, i, lot(n)))
	_ => "no case"
}

## The lot of a `unit` case: "new" for n = 1, else "old".
lot : I64 -> { id : Str, close_ms : U64 }
lot = |n| { id: if (n == 1) "new" else "old", close_ms: 5 }

open_room! = |o, i, l| {
	o.call!(RpcMethods.open_lot(i), l)?
	Ok("opened")
}

unit_try_text = |r| match r {
	Ok(s) => s
	Err(Remote(AlreadyOpen)) => "AlreadyOpen"
	Err(e) => "Err ${Str.inspect(e)}"
}

unit_text : Try({}, [Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote([AlreadyOpen])]) -> Str
unit_text = |r| match r {
	Ok({}) => "Ok {}"
	Err(Remote(AlreadyOpen)) => "AlreadyOpen"
	Err(Infra(RpcErr(t))) => "RpcErr ${t.message}"
	Err(Infra(BadData(s))) => "BadData ${s}"
}

## The text of a call of `fail` or `relay`: the caller matches the tags of `Remote(Infra(..))` by name, so the payload of
## each one is read as its own type. `Infra(RpcErr)` and `Infra(BadData)` are the failures of the call itself.
fail_text : Try(I64, [Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote([NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])]) -> Str
fail_text = |r| match r {
	Ok(v) => "Ok ${v.to_str()}"
	Err(Remote(NotOpen)) => "NotOpen"
	Err(Remote(Infra(StorageErr(t)))) => "Remote StorageErr ${t.name} | ${t.message}"
	Err(Remote(Infra(SqlErr(t)))) => "Remote SqlErr ${t.name} | ${t.message}"
	Err(Remote(Infra(D1Err(t)))) => "Remote D1Err ${t.name} | ${t.message}"
	Err(Remote(Constraint(c))) => "Remote Constraint ${Str.inspect(c.kind)} | ${c.message}"
	Err(Remote(Infra(RpcErr(t)))) => "Remote RpcErr ${t.message}"
	Err(Remote(Infra(i))) => "Remote other ${Str.inspect(i)}"
	Err(Infra(RpcErr(t))) => "RpcErr ${t.message}"
	Err(Infra(BadData(_))) => "BadData"
}

map_text : Try(I64, [Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote([Shut, Constraint(Sql.Constraint), Infra(Rpc.Infra)])]) -> Str
map_text = |r| match r {
	Ok(v) => "Ok ${v.to_str()}"
	Err(Remote(Shut)) => "Shut"
	Err(Remote(Constraint(c))) => "Remote Constraint ${Str.inspect(c.kind)} | ${c.message}"
	Err(Remote(Infra(StorageErr(t)))) => "Remote StorageErr ${t.name} | ${t.message}"
	Err(Remote(Infra(SqlErr(t)))) => "Remote SqlErr ${t.name} | ${t.message}"
	Err(Remote(Infra(D1Err(t)))) => "Remote D1Err ${t.name} | ${t.message}"
	Err(Remote(Infra(RpcErr(t)))) => "Remote RpcErr ${t.message}"
	Err(Remote(Infra(i))) => "Remote other ${Str.inspect(i)}"
	Err(Infra(RpcErr(t))) => "RpcErr ${t.message}"
	Err(Infra(BadData(_))) => "BadData"
}

# The caller matches each tag of the error by its name: a wrong tag does not compile.
busy_text : Try(I64, [Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote([Busy(Str), StillOpen])]) -> Str
busy_text = |r| match r {
	Ok(v) => "Ok ${v.to_str()}"
	Err(Remote(Busy(s))) => "Busy ${s}"
	Err(Remote(StillOpen)) => "StillOpen"
	Err(Infra(RpcErr(t))) => "RpcErr ${t.message}"
	Err(Infra(BadData(_))) => "BadData"
}

noerr_text : Try(I64, [Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote(Rpc.NoErr)]) -> Str
noerr_text = |r| match r {
	Ok(v) => "Ok ${v.to_str()}"
	Err(Infra(RpcErr(t))) => "RpcErr ${t.message}"
	Err(Infra(BadData(_))) => "BadData"
}

busy! : self, { n : I64 } => Try(I64, [Busy(Str), StillOpen])
busy! = |_self, { n }| match n {
	1 => Ok(2)
	2 => Err(Busy("later"))
	_ => Err(StillOpen)
}

crashes! : self, { n : I64 } => Try(I64, Rpc.NoErr)
crashes! = |_self, { n }| if (n >= 0) crash "rpc callee crash" else Ok(n)

open_lot! : self, { id : Str, close_ms : U64 } => Try({}, [AlreadyOpen])
open_lot! = |_self, l| if (l.id == "new") Ok({}) else Err(AlreadyOpen)

mismatch! : self, { n : I64 } => Try(I64, [Surprise])
mismatch! = |_self, { n }| if (n >= 0) Err(Surprise) else Ok(n)

# N5 G1a: the callees of `fail` in the Workers (the default export and `Admin`). A D1 error is `Infra(D1Err)`: the handler passes it on with `?`.
fail_svc! : self, { kind : Str } => Try(I64, [NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
fail_svc! = |_self, { kind }| match kind {
	"d1" => {
		db.exec!("SELEC 1")?
		Ok(1)
	}
	"domain" => Err(NotOpen)
	"crash" => crash "fail callee crash"
	_ => Ok(7)
}

# `Rpc.forward(|e| e)`: the same `err` as `fail`.
relay_svc! : self, { kind : Str } => Try(I64, [NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
relay_svc! = |_self, arg| {
	v = self_service.call!(RpcMethods.fail(RpcMethods.default_iface), arg) ? Rpc.forward(|e| e)
	Ok(v)
}

# `Rpc.forward` with a domain mapping: `NotOpen` is `Shut`, `Infra` stays.
relay_map_svc! : self, { kind : Str } => Try(I64, [Shut, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
relay_map_svc! = |_self, arg| {
	v = self_service.call!(RpcMethods.fail(RpcMethods.default_iface), arg) ? Rpc.forward(
		|e| match e {
			NotOpen => Shut
			Constraint(c) => Constraint(c)
			Infra(i) => Infra(i)
		},
	)
	Ok(v)
}
