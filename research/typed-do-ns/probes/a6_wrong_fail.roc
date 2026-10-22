## The interface as an argument of `namespace_named` and `namespace_remote` (user decision after the study):
## a missing interface is a compile error. Models only (no platform). Variant V1: a value of a phantom type
## `Iface(iface)`. Run: roc check --no-cache.

Iface(iface) := {}

Namespace(iface) :: { binding : Str, class : Str }.{
	named : Namespace(iface), Str -> Stub(iface)
	named = |ns, id| Stub.{ binding: ns.binding, target: id }
}

Stub(iface) :: { binding : Str, target : Str }.{
	call : Stub(iface), Rpc(iface, arg, ret, err), arg -> Str
	call = |s, m, _a| "${s.binding}/${s.target}.${m.name}"
}

Rpc(iface, arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc(iface, arg, ret, err)
	method = |name| Rpc.{ name }
}

namespace_named : Str, Str, Iface(iface) -> Namespace(iface)
namespace_named = |binding, class, _i| Namespace.{ binding, class }

Room := []
Ledger := []

room : Iface(Room)
room = Iface.{}

open : Rpc(Room, {}, U64, [NotOpen])
open = Rpc.method("open")

settle : Rpc(Ledger, {}, U64, [])
settle = Rpc.method("settle")

rooms = namespace_named("ROOMS", "Room", room)

main! = |_args| {
	echo!(rooms.named("a").call(settle, {}))
	Ok({})
}
