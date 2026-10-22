# Typed Durable Object namespaces (design study)

Problem: `examples/auction/REVIEW.md` N4 and `MODULES.md` 7 ("Namespace and class", "Not built"). Today
`lot_rooms.named(id).call!(Gavel.open, lot)` compiles for each `Rpc` value, also for a method that the class
`LotRoom` does not have. The wrong call fails only at run time (`RpcErr`, "does not implement the method").

Goal: a namespace where `call!` compiles only for the Rpc methods that its class serves.

This study changes no file of `platform/`, `bench/`, `conformance/` or `examples/`. The platform changes are in two
generated copies (`platform-a/`, `platform-b/`, not in git).

Compiler: the pinned nightly (`nightly-2026-10-19-601b54c`), each build with `--no-cache`.

## 1. Files

| File | What it is |
| --- | --- |
| `run.sh` | Runs all probes and builds. Run from the submodule root: `research/typed-do-ns/run.sh` (about 4.5 min). |
| `probes/*.roc` | Models of the types with no platform (`roc --no-cache` or `roc check --no-cache`). |
| `make_platform_a.py` | Makes `platform-a/`: `platform/` with option A. |
| `make_platform_b.py` | Makes `platform-b/`: `platform/` with option B. |
| `auction-a/`, `auction-b/`, `auction-c/` | The auction example (`examples/auction/*.roc`) with each option. Option C uses the real `platform/`. |
| `small/{base,a,b}.roc` | A small app (one class, two Rpc methods, one call) for the wasm size. |
| `fail-*/` | Made by `run.sh`: an app copy with one wrong use (not in git). |

## 2. Options

| Id | Form | Platform change |
| --- | --- | --- |
| A | Phantom interface type. `Rpc(iface, arg, ret, err)`. `Object(iface)`, `Object.Namespace(iface)`, `Object.Class(iface)`, `Service(iface)`. The interface is a type with no values in the shared module (`Gavel.Room := []`). | Yes |
| B | Interface record. `Gavel.Room : { open : Rpc(..), snapshot : Rpc(..), .. }` and a value `Gavel.room`. The namespace and the stub carry the record. `call!` takes a function that picks a field: `call!(\|r\| r.open, lot)`. `Rpc` keeps 3 type arguments. | Yes |
| C | Typed client in the app. `Gavel.Room :: { obj : Object }` with one method for each Rpc (`open!`, `snapshot!`, ...). The app calls `Gavel.Room.at(lot_rooms, id).open!(lot)`. | No |
| A' | As A, but the tag is in the class module (`LotRoom.Api`). | Yes |

A' is not built. The Rpc constants are in `Gavel.roc`, and `LotRoom.roc` imports `Gavel.roc`. A tag in `LotRoom.roc`
makes an import cycle (Gavel needs the tag, LotRoom needs Gavel). Without the cycle, the Rpc constants move into
`LotRoom.roc`, and `ledger.roc` must import the class module (all of its code) to call the room. So the tag goes in
the shared module, and A' is A.

A record accessor as a value (`call!(.open, lot)`) does not parse on the pinned nightly (`probes/b2_accessor.roc`):

```
── ✗ unexpected expression syntax ─ research/typed-do-ns/probes/b2_accessor.roc:40:34
I was parsing an expression, and this token cannot start an expression here.
echo!(lot_rooms.named("a").call(.snapshot, {}))
                                ^^^^^^^^^
```

So option B uses `|r| r.open`.

## 3. Comparison

| Item | A: phantom | B: record | C: typed client |
| --- | --- | --- | --- |
| Compiles on the pinned nightly | Yes: `web.roc`, `ledger.roc`, small app | Yes | Yes |
| Wrong method at the caller | Error (type mismatch, see 4) | Error (no field, see 4) | Error (no method, see 4) |
| Wrong method at the callee (class) | Error: all handlers of a class have one interface | No check | No check |
| Namespace tied to its class | Yes: `namespace(.., { class })` takes `iface` from `Object.Class(iface)` | Only by the `iface` value that the app gives | No |
| Escape hatch | `Rpc.method` with another tag (explicit, in the shared module) | `call!(\|_\| Gavel.settle_due, x)` compiles (any Rpc) | `lot_rooms.named(id).call!(any_rpc, x)` still compiles (opt-in only) |
| `namespace_remote`, `namespace_named` | Return `Object.Namespace(iface)`. An annotation names the interface (`lot_rooms : Object.Namespace(Gavel.Room)`). With no annotation, the first `call!` fixes it (see 5). | Take one more field: `iface: Gavel.room` | No change |
| Service binding | Same form: `Service(iface)` (built) | Same form is possible (not built) | A typed client for each service |
| One Rpc on a service and on an object (`conformance` `ping`) | A constant with a free `iface` does not compile ("value is not polymorphic"). Use a function `ping : {} -> Rpc(iface, ..)`, or two constants. | No problem | No problem |
| A JS peer (Rpc served by JS) | As today: the app writes the tag and the Rpc constants. Nothing checks the JS class. | As today, with the record | As today, with the client |
| Code at the call site | `lot_rooms.named(id).call!(Gavel.open, lot)` (no change) | `lot_rooms.named(id).call!(\|r\| r.open, lot)` | `Gavel.Room.at(lot_rooms, id).open!(lot)` |
| Code in the shared module | One `X := []` for each interface, one more type argument on each `Rpc` | One record type and one record value for each interface (each method written 2 more times) | One nominal type, 2 lines for each method (signature with the error type spelled out) |
| Other app changes | `Object.Class(Gavel.Room)` annotation, `objects: [LotRoom.class.erase()]` | `iface:` on each namespace | None |
| Runtime cost | None (types only). `platform-a` maps `erase` on each Rpc event: move it to class creation. | Each stub carries the record (N text values, refcounted) | One more record wrap for each call |
| Compile risks seen | None. `on` still returns a lambda with `Cbor.encode` (#12482 workaround stays), no closed row alias (#12489). | None | None |
| Follow-up error noise | A wrong call gives 1 type mismatch plus 3 "missing method" errors (`arg`, `ret`, `err` stay free) | 1 "no field" error plus "missing method" errors at each user of the result | 1 error |

Wasm size (bytes). The auction builds use the default `--opt`. The small app (`small/`) uses `--opt=size` and
`--opt=speed`.

| App | Base (`platform/`) | A | B | C |
| --- | --- | --- | --- | --- |
| auction `web.roc` | 1595375 | 1596005 (+630) | 1595241 (-134) | 1595039 (-336) |
| auction `ledger.roc` | 973926 | 974043 (+117) | 973848 (-78) | 973662 (-264) |
| small, `--opt=size` | 323380 | 323844 (+464) | 323317 (-63) | not built |
| small, `--opt=speed` | 418046 | 418781 (+735) | 417812 (-234) | not built |

The A increase is the `map(erase)` in `Object.class` and the `erase` of `Object.Class`. All differences are below
0.25 %.

## 4. Error message for a wrong method

A (`fail-a/web.roc`, `run.sh`): the room namespace calls `settle_due`, a method of the ledger.

```
── ✗ type mismatch ────────── research/typed-do-ns/fail-a/web.roc:116:39
The first argument being passed to this function has the wrong type.
snapshot = lot_rooms.named(id).call!(Gavel.settle_due, {})?
                                     ^^^^^^^^^^^^^^^^
This argument has the type:
    Rpc(Gavel.Ledger, {}, { settled: U32 }, Gavel.SettleErr)
But call! needs the first argument to be:
    Rpc(Gavel.Room, arg, ret, err)
      where [
        arg.encoder_for : Cbor -> (arg, List(U8) -> Try(List(U8), [])),
        ...
      ]
── ✗ missing method ───────── research/typed-do-ns/fail-a/web.roc:116:13
This encoder_for call is on a value of type arg, which never resolved to a
concrete type, so it has no encoder_for method.
(and the same for ret and err)
```

A, a service: `ledger.call!(Gavel.close_out, {})` with `ledger : Service(Gavel.Ledger)` gives the same message with
`Rpc(Gavel.Room, ..)` against `Rpc(Gavel.Ledger, arg, ret, err)`.

A, the callee (`fail-a/LotRoom.roc`): the class serves a method of another interface.

```
── ✗ type mismatch ─────────────── research/typed-do-ns/fail-a/LotRoom.roc:38:60
The first two elements in this list have incompatible types.
rpc: [Gavel.settle_due.on(|_s, {}| Ok({ settled: 0 })), Gavel.open.on(open!), ...],
                                                        ^^^^^^^^^^^^^^^^^^^^
The first element has this type:
    Rpc.Serves(Gavel.Ledger, Object.Self)
However, the second element has this type:
    Rpc.Serves(Gavel.Room, Object.Self)
```

B (`fail-b/web.roc`):

```
── ✗ type mismatch ────────── research/typed-do-ns/fail-b/web.roc:115:44
This record does not have a field named settle_due.
snapshot = lot_rooms.named(id).call!(|r| r.settle_due, {})?
                                          ^^^^^^^^^^^
This is often due to a typo. The most similar fields are:
    - close_out
    - open
    - snapshot
```

C (`fail-c/web.roc`):

```
── ✗ missing method ───────── research/typed-do-ns/fail-c/web.roc:115:42
This settle_due! method is being called on a value whose type doesn't have that
method.
snapshot = Gavel.Room.at(lot_rooms, id).settle_due!()?
                                        ^^^^^^^^^^^
The value's type, which does not have a method named settle_due!, is:
    Gavel.Room
```

## 5. Findings of the type checker (option A)

| Case | Result | Probe |
| --- | --- | --- |
| `Rpc(iface, ..) :: { name : Str }`, `iface` used by no field | Compiles | `probes/a_phantom.roc` |
| `lot_rooms = Object.namespace("LOT_ROOM", { class: LotRoom.class })`, no annotation | `iface` comes from the class | `auction-a/web.roc` |
| `lot_rooms = Object.namespace_remote(..)`, no annotation, one `call!` | Compiles. The first `call!` fixes `iface` (the constant is not generalized). A second `call!` with another interface is an error. When the only call is the wrong one, it compiles. | `fail-a/ledger.roc` (the error is at the second call, line 67), `probes/a5_unannotated_trap.roc` |
| A namespace with no annotation and no `call!` (only `declare`) | Compiles (`iface` stays free) | manual build of `ledger.roc` (not in `run.sh`) |
| `ping : Rpc(iface, {}, Str, [])` (a free `iface` in a constant) | Error: "value is not polymorphic". The compiler proposes `ping : {} -> Rpc(iface, ..)`. | `probes/a3_free_iface_fail.roc` |
| `ping : {} -> Rpc(iface, ..)` on a class and on a service | Compiles | `probes/a2_phantom_class.roc` |
| A class with no `rpc` | `iface` is free: annotate (`Object.Class(NoRpc)`) or let the namespace fix it | `probes/a2_phantom_class.roc`, `platform-a/Worker.roc` |
| `Worker.new({ objects: [a, b] })` with two classes | A list has one type, so two interfaces need an erased type: `objects: [a.erase(), b.erase()]` | `auction-a/web.roc` |

The "no annotation" case of `namespace_remote` is a trap: when the only `call!` is the wrong one, the namespace takes
that interface and the build passes. The rule for the docs: annotate each `namespace_remote` and `namespace_named`.

## 6. Recommendation: option A

A is the only option that checks both sides (caller and class) and ties the namespace to the class. The call site does
not change. The cost is one type argument on each `Rpc` annotation, an `X := []` for each interface, and `.erase()` in
`objects`. B gives a noisier call site, no callee check, and a loophole (`|_| any_rpc`). C needs no platform change
but is opt-in and has the most code for each method.

### 6.1 Signatures (as built in `platform-a/`, plus the proposals marked P)

`platform/Rpc.roc`:

```roc
Rpc(iface, arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc(iface, arg, ret, err)
	name : Rpc(iface, arg, ret, err) -> Str
	on : Rpc(iface, arg, ret, err), (self, arg => Try(ret, err)) -> Rpc.Serves(iface, self) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on_worker : Rpc(iface, arg, ret, err), (arg => Try(ret, err)) -> Rpc.Handler({}) where [...]
	# P: on_worker gives Rpc.Serves(iface, {}), and Worker.new and Rpc.entrypoint take List(Rpc.Serves(iface, {})).

	Handler(self) : { name : Str, run! : self, List(U8) => Try(List(U8), Str) }
	Serves(iface, self) := { name : Str, run! : self, List(U8) => Try(List(U8), Str) }.{
		erase : Rpc.Serves(iface, self) -> Rpc.Handler(self)
	}
}
```

`platform/Object.roc`:

```roc
Object(iface) :: { namespace : Str, jurisdiction : Str, target : [Named(Str), Id(Str)], location_hint : Str }.{
	namespace : Str, { class : Object.Class(iface), script ?: Str } -> Object.Namespace(iface)
	namespace_remote : Str, { class : Str, script : Str } -> Object.Namespace(iface)
	namespace_named : Str, Str -> Object.Namespace(iface)  # P: the nsnamed branch, with iface
	Namespace(iface) := { binding : Str, jurisdiction : Str, class : Str, script : Str }.{
		named : Object.Namespace(iface), Str -> Object(iface)
		# named_with, from_id, from_id_with, unique!, unique_with!, jurisdiction, declare: Object.Namespace(iface) in, Object(iface) out
	}
	fetch! : Object(iface), Request => Try(Response, [Infra([ObjectErr(Io.Thrown)])])
	call! : Object(iface), Rpc(iface, arg, ret, err), arg => Try(ret, [Remote(err), Infra([RpcErr(Io.Thrown), BadData(Str)])]) where [...]
	call : Object(iface), Rpc(iface, arg, ret, err), arg -> Io(ret, [...]) where [...]
	id! : Object(iface) => Try(Str, [Infra([ObjectErr(Io.Thrown)])])
	class : Str, { ..., rpc ?: List(Rpc.Serves(iface, Object.Self)), ... } -> Object.Class(iface)
	Class(iface) := { name : Str, handlers : List(Str), methods : List(Str), run! : Str, Object.Event => [...] }.{
		name : Object.Class(iface) -> Str
		erase : Object.Class(iface) -> Object.AnyClass
	}
	AnyClass : { name : Str, handlers : List(Str), methods : List(Str), run! : Str, Object.Event => [...] }
}
```

`platform/Service.roc` and `platform/Worker.roc`:

```roc
Service(iface) :: { name : Str, service : Str, entrypoint : Str }.{
	binding : Str -> Service(iface)
	binding_with : Str, { service ?: Str, entrypoint ?: Str } -> Service(iface)
	call! : Service(iface), Rpc(iface, arg, ret, err), arg => Try(ret, [...]) where [...]
}
# Worker.new: objects ?: List(Object.AnyClass)
```

### 6.2 Before and after (auction)

`Gavel.roc`:

```roc
# Before
open : Rpc(Gavel.Lot, {}, Gavel.RoomErr)
settle_due : Rpc({}, { settled : U32 }, Gavel.SettleErr)

# After
## The interface of a lot room: a type with no values.
Room := []
Ledger := []

open : Rpc(Gavel.Room, Gavel.Lot, {}, Gavel.RoomErr)
settle_due : Rpc(Gavel.Ledger, {}, { settled : U32 }, Gavel.SettleErr)
```

`LotRoom.roc`:

```roc
# Before
class : Object.Class
# After
class : Object.Class(Gavel.Room)
# The body does not change: rpc: [Gavel.open.on(open!), Gavel.snapshot.on(snapshot!), Gavel.close_out.on(close_out!)]
```

`web.roc`:

```roc
# No change: the interface comes from the class.
lot_rooms = Object.namespace("LOT_ROOM", { class: LotRoom.class })
snapshot = lot_rooms.named(id).call!(Gavel.snapshot, {})?

# Optional: the annotation is inferred from ledger.call!(Gavel.settle_due, {}).
ledger : Service(Gavel.Ledger)
ledger = Service.binding_with("LEDGER", { service: "auction-ledger" })

# Before: objects: [LotRoom.class]
objects: [LotRoom.class.erase()],
```

`ledger.roc`:

```roc
## The class `LotRoom` is in the script of auction-web.
lot_rooms : Object.Namespace(Gavel.Room)
lot_rooms = Object.namespace_remote("LOT_ROOM", { class: "LotRoom", script: "auction-web" })
closeout = lot_rooms.named(id).call!(Gavel.close_out, {})?  # no change
```

A JS class or a class in another Worker, or a class behind an import cycle (`namespace_named`): the app writes the tag
and the Rpc constants in a module that both sides import, and annotates the namespace:

```roc
JsRoom := []
ping : Rpc(JsRoom, { n : I64 }, Str, Rpc.NoErr)
ping = Rpc.method("ping")

js_rooms : Object.Namespace(JsRoom)
js_rooms = Object.namespace_remote("JS_ROOM", { class: "JsRoom", script: "js-worker" })
```

The types do not check the JS class: a method that it does not have is `RpcErr` at run time, as today.

### 6.3 Migration list (if the platform takes option A)

Counts are from `grep` on main (2026-10-22).

| Where | Change | Sites |
| --- | --- | --- |
| `platform/Rpc.roc` | `Rpc(iface, ..)`, `Rpc.Serves`, `on` gives `Serves` | 1 module |
| `platform/Object.roc` | `Object(iface)`, `Namespace(iface)`, `Class(iface)`, `AnyClass`, all signatures (`make_platform_a.py` does it with one regex) | 1 module |
| `platform/Service.roc`, `Remote.roc`, `Worker.roc` | `Service(iface)`, `Remote.call` type, `objects : List(Object.AnyClass)`, the `expect`s of `Worker.roc` (a class constant with an annotation) | 3 modules |
| `bench/platform/` | Made by `bench/build.sh` from `platform/` | none by hand |
| `conformance/*.roc` | 26 `Rpc(` annotations, 9 `Object.Class` annotations, 4 `objects:` lists, 2 `namespace_remote` (annotate), 6 `Service.binding` (annotate when a service calls methods of 2 interfaces) | about 47 |
| `conformance/RpcMethods.roc` | `ping`, `hello`, `busy`: one constant for a class and a service. Make each a function of `{}`, or 2 constants. | 3 to 6 |
| `conformance/must-not-compile/` | New case: a wrong method on an object, and on a class | 2 new |
| `bench/*.roc`, `edge/` | 2 `objects:` lists, 2 `Object.namespace(`, 1 `objects:` in `edge/` | 5 |
| `examples/auction/` | 4 `Rpc(`, 1 `Object.Class`, 1 `objects:`, 1 `namespace_remote` | 7 |
| `MODULES.md` 7 and 8, `API.md` | The signatures, the "Not built" row becomes "As built", the rule "annotate `namespace_remote`" | docs |

## 7. Open questions

| # | Question |
| --- | --- |
| Q1 | The name of the erase step for `Worker.new({ objects })`: `LotRoom.class.erase()`, or another name (`any()`)? Or should `Object.class` give both (a record `{ class, typed }`)? |
| Q2 | Typed services and entry points (`Service(iface)`, `on_worker` and `Rpc.entrypoint` with `Rpc.Serves(iface, {})`): in the same step, or objects only first? `platform-a` types `Service` and keeps `on_worker` erased. |
| Q3 | The conformance pattern "one Rpc constant on a class and on a service" (`ping`, `hello`, `busy`): a function of `{}` (`RpcMethods.ping({})`), or 2 constants? Real apps seldom need it. |
| Q4 | The name of the interface type: `Gavel.Room` (the role) or `Gavel.LotRoomApi`? A rule for the docs. |
| Q5 | Should `namespace_remote` and `namespace_named` require the interface by a parameter (for example `{ class : Str, script : Str, iface : Object.Iface(iface) }` with `Object.Iface(iface) := {}`) so that a missing annotation is an error and not the trap of 5? |
| Q6 | The follow-up "missing method" errors (3 for one wrong call) are compiler noise. File upstream, or accept? |
| Q7 | Runtime: the probes only compile. A conformance run on `platform-a` (after the migration) is needed to show no change in behavior. |
