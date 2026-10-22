## Option A, the callee side and the edge cases:
## 1. `Class(iface)` from its handlers, and `namespace(binding, { class })` takes `iface` from the class.
## 2. A namespace with no annotation (`iface` from its use).
## 3. An `Rpc` constant with a free `iface` (one method on a service and on an object).
## 4. A class with no `rpc` (a free `iface`).
## 5. A service (`Service(iface)`) and an entry point.

Rpc(iface, arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc(iface, arg, ret, err)
	method = |name| Rpc.{ name }

	name : Rpc(iface, arg, ret, err) -> Str
	name = |m| m.name

	## The model keeps the name only: the codecs are in the platform copy (`platform-a/`).
	on : Rpc(iface, arg, ret, err), (self, arg => Try(ret, err)) -> Handler(iface, self)
	on = |m, _f!| Handler.{ name: m.name }
}

Handler(iface, self) :: { name : Str }.{
	name : Handler(iface, self) -> Str
	name = |h| h.name
}

Self :: { id : Str }

Class(iface) :: { name : Str, methods : List(Str) }

class : Str, { rpc ?: List(Handler(iface, Self)) } -> Class(iface)
class = |name, h| Class.{ name, methods: (h.?rpc ?? []).map(|m| m.name()) }

Stub(iface) :: { binding : Str, target : Str }.{
	call : Stub(iface), Rpc(iface, arg, ret, err), arg -> Str
	call = |s, m, _a| "${s.binding}/${s.target}.${m.name()}"
}

Namespace(iface) :: { binding : Str, class : Str }.{
	named : Namespace(iface), Str -> Stub(iface)
	named = |ns, id| Stub.{ binding: ns.binding, target: id }
}

namespace : Str, { class : Class(iface) } -> Namespace(iface)
namespace = |binding, opts| {
	c : Class(iface)
	c = opts.class
	Namespace.{ binding, class: class_name(c) }
}

class_name : Class(iface) -> Str
class_name = |c| c.name

## A service binding: the same phantom.
Service(iface) :: { binding : Str }.{
	call : Service(iface), Rpc(iface, arg, ret, err), arg -> Str
	call = |s, m, _a| "${s.binding}.${m.name()}"
}

service : Str -> Service(iface)
service = |binding| Service.{ binding }

# ---- Shared ----

Room := []

Lot : { id : Str }

open : Rpc(Room, Lot, {}, [NotOpen])
open = Rpc.method("open")

snapshot : Rpc(Room, {}, U64, [NotOpen])
snapshot = Rpc.method("snapshot")

## 3. A method with no fixed interface: on a service and on an object. A constant with a free `iface` does not
## compile ("value is not polymorphic", a3_free_iface_fail.roc), so it is a function of `{}`.
ping : {} -> Rpc(iface, {}, Str, [])
ping = |{}| Rpc.method("ping")

# ---- The class (LotRoom.roc) ----

open! : Self, Lot => Try({}, [NotOpen])
open! = |_self, _lot| Ok({})

snapshot! : Self, {} => Try(U64, [NotOpen])
snapshot! = |_self, {}| Ok(7)

ping! : Self, {} => Try(Str, [])
ping! = |_self, {}| Ok("pong")

lot_room : Class(Room)
lot_room = class("LotRoom", { rpc: [open.on(open!), snapshot.on(snapshot!), ping({}).on(ping!)] })

## 4. No rpc: the interface is free, and the annotation picks one.
plain : Class(Room)
plain = class("Plain", {})

# ---- The caller (web.roc) ----

## 2. No annotation: `iface` comes from the class.
lot_rooms = namespace("LOT_ROOM", { class: lot_room })

plain_ns : Namespace(Room)
plain_ns = namespace("PLAIN", { class: plain })

Ledger := []

ledger : Service(Ledger)
ledger = service("LEDGER")

main! = |_args| {
	echo!(lot_rooms.named("a").call(open, { id: "a" }))
	echo!(lot_rooms.named("a").call(ping({}), {}))
	echo!(plain_ns.named("b").call(snapshot, {}))
	echo!(ledger.call(ping({}), {}))
	Ok({})
}
