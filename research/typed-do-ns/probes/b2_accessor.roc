## Option B with a record accessor as a value (`.snapshot`): does the parser take it?
## that picks one field. `Rpc` keeps its 3 type arguments. A model with no platform.

Rpc(arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc(arg, ret, err)
	method = |name| Rpc.{ name }

	name : Rpc(arg, ret, err) -> Str
	name = |m| m.name
}

Stub(r) :: { binding : Str, target : Str, iface : r }.{
	call : Stub(r), (r -> Rpc(arg, ret, err)), arg -> Str
	call = |s, pick, _a| "${s.binding}/${s.target}.${pick(s.iface).name()}"
}

Namespace(r) :: { binding : Str, class : Str, iface : r }.{
	named : Namespace(r), Str -> Stub(r)
	named = |ns, id| Stub.{ binding: ns.binding, target: id, iface: ns.iface }
}

namespace_remote : Str, { iface : r, class : Str, script : Str } -> Namespace(r)
namespace_remote = |binding, opts| Namespace.{ binding, class: opts.class, iface: opts.iface }

# ---- Shared (Gavel.roc) ----

Lot : { id : Str }

Room : { open : Rpc(Lot, {}, [NotOpen]), snapshot : Rpc({}, U64, [NotOpen]) }

room : Room
room = { open: Rpc.method("open"), snapshot: Rpc.method("snapshot") }

# ---- The caller ----

lot_rooms = namespace_remote("LOT_ROOM", { iface: room, class: "LotRoom", script: "auction-web" })

main! = |_args| {
	echo!(lot_rooms.named("a").call(|r| r.open, { id: "a" }))
	echo!(lot_rooms.named("a").call(.snapshot, {}))
	Ok({})
}
