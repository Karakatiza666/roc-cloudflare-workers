## Option A: a phantom interface type on `Rpc`: `Rpc(iface, arg, ret, err)`. A namespace and a stub carry `iface`.
## A model of the platform types with no platform (run: `roc --no-cache a_phantom.roc`).

Rpc(iface, arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc(iface, arg, ret, err)
	method = |name| Rpc.{ name }

	name : Rpc(iface, arg, ret, err) -> Str
	name = |m| m.name
}

## A stub of one object. `iface` is a phantom: no field has it.
Stub(iface) :: { binding : Str, target : Str }.{
	call : Stub(iface), Rpc(iface, arg, ret, err), arg -> Str
	call = |s, m, _a| "${s.binding}/${s.target}.${m.name()}"
}

Namespace(iface) :: { binding : Str, class : Str }.{
	named : Namespace(iface), Str -> Stub(iface)
	named = |ns, id| Stub.{ binding: ns.binding, target: id }
}

namespace_remote : Str, { class : Str, script : Str } -> Namespace(iface)
namespace_remote = |binding, opts| Namespace.{ binding, class: opts.class }

# ---- The shared module (Gavel.roc) ----

## The interface of a lot room: a type with no values, used only as a type argument.
Room := []

Ledger := []

Lot : { id : Str }

open : Rpc(Room, Lot, {}, [NotOpen])
open = Rpc.method("open")

snapshot : Rpc(Room, {}, U64, [NotOpen])
snapshot = Rpc.method("snapshot")

settle_due : Rpc(Ledger, {}, U32, [])
settle_due = Rpc.method("settle_due")

# ---- The caller (web.roc) ----

lot_rooms : Namespace(Room)
lot_rooms = namespace_remote("LOT_ROOM", { class: "LotRoom", script: "auction-web" })

main! = |_args| {
	echo!(lot_rooms.named("a").call(open, { id: "a" }))
	echo!(lot_rooms.named("a").call(snapshot, {}))
	Ok({})
}
