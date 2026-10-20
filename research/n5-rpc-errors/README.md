# N5: typed infrastructure errors of an Rpc method (design study, 2026-10-20)

Item N5 of `examples/auction/REVIEW.md` (line 69). Analysis and prototypes only. This study does not change `platform/`, `bench/`, `conformance/` or `examples/`.

Compiler: `bench/get-roc.sh` (nightly-2026-10-19-601b54c), always `--no-cache`. Platform: `../../platform/main.roc` as it is on main (read only). Run all probes from the submodule root:

```sh
research/n5-rpc-errors/run.sh
```

## 1. The problem

Today an Rpc is `Rpc(arg, ret, err)`. The handler gives `Try(ret, err)`, and `err` is closed and CBOR-writable. The caller gets `Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err)])`.

The `?` of a platform call in a handler adds the tag of that call. So `err` must list the infrastructure tags next to the domain tags:

```roc
RoomErr : [NotOpen, AlreadyOpen, StillOpen, StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]
```

| Cost today | Where |
| --- | --- |
| 5 infrastructure tags in a type of 3 domain tags | `examples/auction/Gavel.roc:28` |
| The list grows with each platform module that a handler uses (Kv, D1, R2, ...) | `Gavel.roc:31` (`SettleErr`) |
| The caller matches `Remote(...)` of all 8 tags, with a `_` arm | `examples/auction/web.roc:64` to `77` |

The constraint of the user: an infrastructure error must not become text. The caller must tell a storage error from a SQL error by its tag. The types stay strong from the handler to the caller.

## 2. What the platform gives today

All infrastructure errors of the platform have one of 4 payload forms, all CBOR data: `Io.Thrown` (`{ name : Str, message : Str }`), `Str`, `Sql.Constraint` (a record with a closed tag), or none.

| Group | Tags (count of uses in `platform/*.roc`) |
| --- | --- |
| Storage of an object | `StorageErr(Io.Thrown)` (16), `SqlErr(Io.Thrown)` (8) |
| SQL of D1 and of an object | `Constraint(Sql.Constraint)` (62), `D1Err(Io.Thrown)` (55) |
| Other bindings | `KvErr` (32), `R2Err` (31), `CacheErr` (7), `QueueErr` (9), `AiErr` (7), `VectorizeErr` (16), `WorkflowsErr` (20), `EmailErr` (12), `AnalyticsErr` (1), `AssetsErr` (2), `SecretsStoreErr` (2), `LimitErr` (2), all `(Io.Thrown)` |
| Calls | `ObjectErr` (4), `ServiceErr` (2), `RpcErr` (5), `HttpErr` (10), `Network` (10), `SocketErr` (17), all `(Io.Thrown)` |
| Data and limits | `BadData(Str)` (109), `InvalidJson(Str)` (8), `BodyErr(Io.Thrown)` (23), `CryptoErr(Io.Thrown)` (22), `MissingEnv(Str)` (3), `TooLarge`, `TimedOut` |

These 29 tags can be one closed union. No two of them have the same name with different payloads. The domain-like tags (`NotFound`, `Closed`, `PreconditionFailed`, `NotUpgrade`) are not in it: the handler must decide what they mean.

## 3. Probes

| File | Question | Result |
| --- | --- | --- |
| `q1_extend.roc` | Option B: an alias with a row variable `Infra(e) : [..., ..e]`, given a closed union. Does `?` fit? Does the derived codec work? | Yes and yes |
| `q2_fault.roc` | Option C: `Fault(err) : [Fail(err), <infra tags>]`. `?` direct, `? Fail` for a domain function, an `on` that returns a lambda, a split into `Remote(err)` and `Infra(Infra)` | Works |
| `q3_narrow.roc` | Option D: can a `match` take the infrastructure tags out of a flat open union and give the rest as `..e`? | No. The rest keeps all tags (`type mismatch`) |
| `q4_codec.roc` | Is there a derived CBOR codec for `Fail(e)` when `e` is a constrained type variable (generic code)? | No: `missing method encoder_for`. The type variable alone has one |
| `q5_empty_row.roc` | Is there a derived codec for `InfraOr([])` (a row variable closed with `[]`)? | No: `missing method encoder_for`, but the same union written out has one. Compiler defect candidate |
| `q6_widen.roc`, `q6_widen_fail.roc` | Can a value of the closed `Infra` be a `Fault(err)` with no match? A forward helper for a nested call | No (`type mismatch`): a match is necessary. With a match, the forward helper works |
| `q7_wrap_infra.roc` | Option E: the domain tags flat, `? Infra` at each platform call | Works |
| `option-b/` | The auction example with option B (`RpcB.roc`: one alias, the platform `Rpc` as it is) | `web.roc` and `ledger.roc` build |
| `option-c/` | The auction example with option C (`RpcX.roc`: the proposal as an app module over the platform of today) | `web.roc` and `ledger.roc` build. 5 `expect` tests of the wire bytes pass (a broken `infra_head` fails 2 of them) |

Two findings set the shape of the implementation:

| Finding | Effect on the design |
| --- | --- |
| Q4: a structural union with a payload of a constrained type variable has no derived codec in generic code | The wire type of the platform must be nominal with `parser_for : _` (as `Reply` is today). `RpcX.Reply3` shows it |
| roc-lang/roc#12482: a generic nominal encoded inside a returned lambda crashes | `on` must write the reply heads by hand (as today) and encode only `ret`, `err` or the closed `Infra`. `RpcX.on` does this, and the build has no crash |

## 4. Options

| Option | App code at the handler | App code at the caller | Type size | Breaking changes | Compile risks |
| --- | --- | --- | --- | --- | --- |
| A. Today: list all tags in `err` | None. `err` lists each infrastructure tag that a `?` adds | `Remote(<each tag>)` or `_` | `err` grows with each platform module; wasm: base | None | None |
| B. Flat row alias: `RoomErr : Rpc.InfraOr([NotOpen, ...])` | None. `Err(NotOpen)`, `?` direct | `Remote(NotOpen)`, `Remote(SqlErr(t))`. No single arm for all infrastructure tags (Q3). `Remote(_)` also hides a new domain tag | 32 tags in each `err`. wasm of web +24%, ledger +13% | None: one new alias | Q5: `InfraOr([])` has no codec, so a second list for "no domain error". A domain tag with an infrastructure name (`BadData`) merges with it silently |
| C. Domain in `Fail`, infrastructure flat in the handler, split for the caller (recommended) | `Err(Fail(AlreadyOpen))` at each domain error. `? Fail` for a domain-only function. `?` direct on each platform call | `Remote(e)` has the domain tags only: exhaustive. `Infra(i)`: one arm, or one arm for each tag (`Infra(SqlErr(t))`) | `err` has the domain tags only. One shared `Rpc.Infra`. wasm of web +2.5%, ledger +14% | Each handler's domain errors, each `err` type, each caller arm of an infrastructure tag. The wire gets a third form `{"Infra": tag}` | Q4 and #12482: solved by a nominal `Reply` with a derived parser and heads by hand (proved in `option-c/`) |
| D. Flat handler error, `on` splits it | None | As C | As C | As C | Not possible: no narrowing in Roc (Q3) |
| E. Domain flat, `? Infra` at each platform call | `? Infra` at each platform call (about 12 in the auction, against 3 domain sites for C) | `Remote(NotOpen)`, `Remote(Infra(SqlErr(t)))` | As C | App only: the platform adds the alias `Rpc.Infra` | None found (Q7) |
| F. Infrastructure errors as text | None | Text compare | Small | As C | Rejected by the user |
| G. Each platform function gives `Infra(...)` | None | As C | As C | Each error match of each app, also outside Rpc (`KvErr` becomes `Infra(KvErr)`) | Not prototyped |

## 5. Recommendation: option C

Option C is the only option with all of these:

| Property | A | B | C | E |
| --- | --- | --- | --- | --- |
| `?` on a platform call needs no per-call code | Yes | Yes | Yes | No |
| `err` names only the domain | No | Yes | Yes | Yes |
| The caller can match all infrastructure errors in one arm | No | No | Yes | Yes (`Remote(Infra(_))`) |
| The caller can match the domain exhaustively | Yes | No | Yes | Yes |
| Each infrastructure kind is a typed tag at the caller | Yes | Yes | Yes | Yes |
| The domain and the infrastructure cannot have a name clash | No | No | Yes | Yes |

The cost of C: each domain error in a handler is `Err(Fail(X))`, and a helper that both an Rpc handler and other code use gives `Fail(X)` (see `on_message!` in section 7).

### 5.1 Proposed signatures (`platform/Rpc.roc`)

```roc
Rpc(arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc(arg, ret, err)                                  # no change
	name : Rpc(arg, ret, err) -> Str                                    # no change

	## New. The infrastructure errors of the platform: one closed union, the tags as the platform functions give them.
	Infra : [
		StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), D1Err(Io.Thrown), KvErr(Io.Thrown),
		R2Err(Io.Thrown), CacheErr(Io.Thrown), QueueErr(Io.Thrown), ObjectErr(Io.Thrown), ServiceErr(Io.Thrown),
		RpcErr(Io.Thrown), HttpErr(Io.Thrown), Network(Io.Thrown), SocketErr(Io.Thrown), BodyErr(Io.Thrown),
		CryptoErr(Io.Thrown), AiErr(Io.Thrown), VectorizeErr(Io.Thrown), WorkflowsErr(Io.Thrown), EmailErr(Io.Thrown),
		AnalyticsErr(Io.Thrown), AssetsErr(Io.Thrown), SecretsStoreErr(Io.Thrown), LimitErr(Io.Thrown),
		BadData(Str), InvalidJson(Str), MissingEnv(Str), TooLarge, TimedOut,
	]

	## New. The error of a handler: a domain error in `Fail`, or a tag of `Infra` as it is.
	Fault(err) : [Fail(err), <the 29 tags of Infra>]

	on : Rpc(arg, ret, err), (self, arg => Try(ret, Rpc.Fault(err))) -> Rpc.Handler(self) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on_worker : Rpc(arg, ret, err), (arg => Try(ret, Rpc.Fault(err))) -> Rpc.Handler({}) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	reply_of : List(U8) -> Try(ret, [BadData(Str), Remote(err), Infra(Rpc.Infra)]) where [ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]

	## New, optional (open question 3). A nested call in a handler: the callee's domain error mapped, the rest as it is.
	forward : Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err), Infra(Rpc.Infra)]), (err -> e2) -> Try(ret, Rpc.Fault(e2))

	NoErr := [] ...                                                     # no change: the err of a method with no domain error
	Handler(self), entrypoint, Entrypoint                               # no change
}

Reply(ret, err) := [Ok(ret), Err(err), Infra(Rpc.Infra)].{ parser_for : _, encoder_for : _, is_eq : _ }   # a third form
infra_head : List(U8)
infra_head = [0xa1, 0x65, 0x49, 0x6e, 0x66, 0x72, 0x61]              # {"Infra": ...}, checked by an expect in RpcX.roc

# platform/Object.roc and platform/Service.roc (and their twins in Remote.roc)
call! : Object, Rpc(arg, ret, err), arg => Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err), Infra(Rpc.Infra)]) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
call! : Service, Rpc(arg, ret, err), arg => Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err), Infra(Rpc.Infra)]) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
```

The body of `on` is `RpcX.on` (`option-c/RpcX.roc`) with no `fail_head`: `Fail(e)` writes `err_head` and `Cbor.encode(e)`, a tag of `Infra` writes `infra_head` and `Cbor.encode(i)`. A private `split : Rpc.Fault(err) -> Try(err, Rpc.Infra)` (`RpcX.split`, one arm for each tag) gives the two cases. Q6 shows that the split needs the match: a closed value does not widen.

### 5.2 The wire

| Handler result | Bytes (CBOR) | JSON view for a JS peer | Caller gets |
| --- | --- | --- | --- |
| `Ok(v)` | `{"Ok": v}` | `{ Ok: v }` (no change) | `Ok(v)` |
| `Err(Fail(e))` | `{"Err": e}` | `{ Err: "NotOpen" }` (no change) | `Err(Remote(e))` |
| `Err(StorageErr(t))` (any tag of `Infra`) | `{"Infra": {"StorageErr": t}}` | `{ Infra: { StorageErr: { name, message } } }` (new) | `Err(Infra(StorageErr(t)))` |
| A throw | JS throw | (no change) | `Err(RpcErr(t))` |
| Bytes that do not fit `Reply` | | | `Err(BadData(s))` |

A domain reply has the same bytes as today. A JS callee can give the third form. `js/` passes the reply through, so it needs no code change (only the comment at `js/index.js:216`).

The prototype `option-c/` cannot change the platform `Reply`, so its wire is `{"Err": {"Fail": e}}` or `{"Err": {"Infra": i}}` (nominal `RpcX.Wire`). `RpcX.reply_of3` and its `expect` tests prove the parse of the three-form `Reply`.

## 6. Probe results in detail

| Check | Command | Result |
| --- | --- | --- |
| Option C, `web.roc` | `roc build --target=wasm32 --no-cache` | 0 errors, 21 s (base 19 s) |
| Option C, `ledger.roc` | same | 0 errors |
| Option C, wire bytes | `roc test --no-cache option-c/web.roc` | 181 passed. With `infra_head` changed: 2 failed |
| Option C, a handler annotated `Rpc.Fault(Gavel.RoomErr)` that uses `?` on `load_state!` (closed `[Fail([NotOpen]), BadData(Str), StorageErr(Io.Thrown)]`) | build | 0 errors: the result of a function widens at `?`, also inside `Fail` |
| Option C, `snapshot!` and `close_out!` with `_` in place of the annotation | build (first run) | 0 errors |
| Option B, `web.roc` and `ledger.roc` | build | 0 errors (after the second list of Q5) |
| wasm size, web (no `--opt`) | `stat` | base 1,454,418; B 1,798,425; C 1,491,061 |
| wasm size, ledger (no `--opt`) | `stat` | base 890,245; B 1,009,547; C 1,016,584 |

## 7. The auction example, before and after (option C, platform names)

The files in `option-c/` use `RpcX.on(Gavel.open, open!)` and `RpcX.call!(obj, m, a)`, because they cannot change the platform. With the platform change, the app keeps `Gavel.open.on(open!)` and `obj.call!(m, a)`. The snippets show the platform form.

`Gavel.roc:27` to `31`:

```roc
# Before
RoomErr : [NotOpen, AlreadyOpen, StillOpen, StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]
SettleErr : [D1Err(Io.Thrown), Constraint(Sql.Constraint), KvErr(Io.Thrown), BadData(Str), TooLarge]
settle_due : Rpc({}, { settled : U32 }, Gavel.SettleErr)

# After
## The domain errors of a lot room. The infrastructure errors are `Rpc.Infra`.
RoomErr : [NotOpen, AlreadyOpen, StillOpen]
settle_due : Rpc({}, { settled : U32 }, Rpc.NoErr)
```

`LotRoom.roc:187` (`open!`):

```roc
# Before
open! : Object.Self, Gavel.Lot => Try({}, _)
open! = |self, lot| match state_cell.get!(self) {
	Ok(_) => Err(AlreadyOpen)
	Err(NotFound) => {
		state_cell.set!(self, { status: Open, ... })?
		self.set_alarm_at!(lot.close_ms)?
		Ok({})
	}
	Err(BadData(s)) => Err(BadData(s))
	Err(StorageErr(t)) => Err(StorageErr(t))
}

# After (the annotation is optional: `_` also builds, `on` closes the type)
open! : Object.Self, Gavel.Lot => Try({}, Rpc.Fault(Gavel.RoomErr))
open! = |self, lot| match state_cell.get!(self) {
	Ok(_) => Err(Fail(AlreadyOpen))
	Err(NotFound) => {
		state_cell.set!(self, { status: Open, ... })?
		self.set_alarm_at!(lot.close_ms)?
		Ok({})
	}
	Err(BadData(s)) => Err(BadData(s))
	Err(StorageErr(t)) => Err(StorageErr(t))
}
```

A helper that an Rpc handler and the socket code both use (`LotRoom.roc:80` and `132`):

```roc
# After
load_state! : Object.Self => Try(State, [Fail([NotOpen]), BadData(Str), StorageErr(Io.Thrown)])
...
	Err(NotFound) => Err(Fail(NotOpen))

# on_message!: check_bid gives NotOpen, load_state! gives Fail(NotOpen)
	Err(Fail(NotOpen)) | Err(NotOpen) => reject!(socket, "the lot is not open")
```

`web.roc:64` to `77` (`error_response!`):

```roc
# Before
error_response! : [NotFound, Unauthorized, BadRequest(Str), BadData(Str), Constraint(_), Remote(Gavel.RoomErr), ..] => Response
error_response! = |e| match e {
	NotFound => Response.from_text(404, "not found")
	Remote(NotOpen) => Response.from_text(404, "the lot room is not open")
	Remote(AlreadyOpen) => Response.from_text(409, "the lot room is open")
	...
	_ => { Log.error!("request failed", Str.inspect(e)); Response.from_text(500, "server error") }
}

# After
error_response! : [NotFound, Unauthorized, BadRequest(Str), BadData(Str), Constraint(_), Remote(Gavel.RoomErr), Infra(Rpc.Infra), ..] => Response
error_response! = |e| match e {
	NotFound => Response.from_text(404, "not found")
	Remote(NotOpen) => Response.from_text(404, "the lot room is not open")
	Remote(AlreadyOpen) => Response.from_text(409, "the lot room is open")
	Remote(StillOpen) => Response.from_text(409, "the lot is still open")
	Infra(StorageErr(_)) | Infra(SqlErr(_)) => {
		Log.error!("lot room storage failed", Str.inspect(e))
		Response.from_text(503, "the lot room is not available")
	}
	...
	_ => { Log.error!("request failed", Str.inspect(e)); Response.from_text(500, "server error") }
}
```

`ledger.roc:41` and `154`:

```roc
# Before
settle_due! : {} => Try({ settled : U32 }, Gavel.SettleErr)
# After: no domain error, all `?` are platform calls
settle_due! : {} => Try({ settled : U32 }, Rpc.Fault(Rpc.NoErr))
```

## 8. Migration list

| File | Change |
| --- | --- |
| `platform/Rpc.roc` | `Infra`, `Fault(err)`, private `split`, optional `forward`. New types of `on`, `on_worker`, `reply_of`. The body of `on` (third head). `Reply` with `Infra(Rpc.Infra)`. `infra_head` |
| `platform/Object.roc`, `platform/Service.roc`, `platform/Remote.roc` | The result type of `call!` and of its twin `call` |
| `bench/platform/` (the same 4 files) | The same change (copy of the platform) |
| `js/index.js:216` | The comment names the third form. No code change |
| `MODULES.md` 8 | The code block, the example (`close_out!`, the caller match), the "Errors" row, the "As built" rows of `Reply`, `call!`, `Rpc.NoErr` |
| `API.md`, `PLAN.md` (8h table) | A row for N5 |
| `conformance/RpcErrRoutes.roc`, `RpcMethods.roc`, `RpcRoutes.roc`, `ObjectRoutes.roc`, `DecRoutes.roc` | Domain errors in `Fail`. Caller types with `Infra(Rpc.Infra)` |
| `conformance/checks/rpcerr.mjs` | New checks: a Roc callee with a storage error gives `Infra(StorageErr(..))`. A JS callee that replies `{ Infra: ... }`. A domain reply has the same bytes as before |
| `conformance/must-not-compile/rpc_tag_bad.roc`, `rpc_tag_ok.roc` | A domain tag with no `Fail`, and a tag that is in neither `err` nor `Infra`, do not compile |
| `conformance/reverts.mjs` | The entry of the `on` signature (line 629). New entries: `infra_head` bytes, one arm of `split` that gives `Fail` |
| `examples/auction/Gavel.roc`, `LotRoom.roc`, `web.roc`, `ledger.roc` | As section 7 (`option-c/` is the diff, less the `RpcX.` names) |
| `examples/auction/REVIEW.md` | N5: done |

## 9. Open questions

| # | Question | Default of this study |
| --- | --- | --- |
| 1 | Names: `Fail(err)`, `Rpc.Fault(err)`, `Rpc.Infra`, the reply key `"Infra"` | As written |
| 2 | Members of `Rpc.Infra`. Are `RpcErr` (a nested call threw), `MissingEnv`, `InvalidJson`, `TimedOut` infrastructure or domain? A new platform module must add its tag to `Infra` | All 29 of section 2 |
| 3 | Add `Rpc.forward` now (q6 proves the shape), or later? | Later: the auction has no nested call that gives its errors to its caller |
| 4 | The third reply form `{ Infra: ... }` becomes part of the contract for a JS peer (MODULES.md 8). OK? | Yes |
| 5 | Q4 and Q5 are compiler limits. Report them upstream (as #12482)? | Yes, Q5 first (the same union written out has a codec) |
| 6 | A caller `_` arm still catches a new domain tag. Should the docs show an exhaustive `Remote(r) => room_response(r)` form? | A sentence in MODULES.md 8 |
