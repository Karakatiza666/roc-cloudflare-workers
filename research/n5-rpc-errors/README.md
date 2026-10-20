# N5: typed infrastructure errors of an Rpc method (design study, 2026-10-20)

Item N5 of `examples/auction/REVIEW.md` (line 69). Analysis and prototypes only. This study does not change `platform/`, `bench/`, `conformance/` or `examples/`.

Compiler: `bench/get-roc.sh` (nightly-2026-10-19-601b54c), always `--no-cache`. Base: main at `4367d73` (the auction with `Dec`). Run all probes and builds from the submodule root:

```sh
research/n5-rpc-errors/run.sh            # wasm with no --opt
OPT=size research/n5-rpc-errors/run.sh   # wasm with --opt=size
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

## 2. Final result

| | C: domain in `Fail` | E: `? Infra` at each call | G1a: platform gives `Infra([own tags])` | G2: platform gives `Infra(Rpc.Infra)` |
| --- | --- | --- | --- | --- |
| Handler, domain error | `Err(Fail(AlreadyOpen))` | `Err(AlreadyOpen)` | `Err(AlreadyOpen)` | `Err(AlreadyOpen)` |
| Handler, platform call | `x!(...)?` | `x!(...) ? Infra` (8 sites in the auction) | `x!(...)?` | `x!(...)?` |
| Handler, re-raise after a match (`NotFound` of a cell) | 2 arms (`BadData`, `StorageErr`) | 2 arms, each wrapped in `Infra` | 1 arm: `Err(Infra(i)) => Err(Infra(i))` | 1 arm |
| Caller, domain | `Remote(NotOpen)`, exhaustive | `Remote(NotOpen)` | `Remote(NotOpen)` | `Remote(NotOpen)` |
| Caller, infrastructure of the callee | `Infra(StorageErr(t))` | `Remote(Infra(StorageErr(t)))` | `Remote(Infra(StorageErr(t)))` | `Remote(Infra(StorageErr(t)))` |
| Caller, this hop failed | `RpcErr(t)`, `BadData(s)` (flat) | `RpcErr(t)`, `BadData(s)` (flat) | `Infra(RpcErr(t))`, `Infra(BadData(s))` | as G1a |
| One shape for all infrastructure errors | No: the hop is flat, the callee is in `Infra` | No: the hop is flat | Yes: `Infra(..)` here, `Remote(Infra(..))` there | Yes |
| Code outside Rpc | No change | No change (helpers on the Rpc paths get `Infra`) | Each match on an infrastructure tag gets `Infra(..)` (auction: 2 arms) | As G1a, and an exhaustive match needs `Infra(_)` |
| Type of a platform function | Flat and precise (as today) | Flat and precise | Nested and precise: `Kv.Cell.get!` says `Infra([KvErr, BadData, TooLarge])` | Nested, not precise: a Kv call says that it can give `SqlErr` |
| Wire | New third form `{"Infra": tag}` | No change | No change (`{"Err": {"Infra": tag}}`) | No change |
| Platform change | `Rpc.on`, `Reply`, `call!` (about 10 signatures) | One alias `Rpc.Infra` | Each public function with an infrastructure tag (294 signature lines in `platform/`), `call!`, `Io.timeout` | As G1a |
| App lines changed (auction, 4 files) | 30 | 23 | 18 | not built |
| wasm web, no `--opt` (base 1,459,868) | 1,496,483 (+2.5%) | 1,597,426 (+9.4%) | 1,544,113 (+5.8%) | not built |
| wasm web, `--opt=size` (base 1,240,680) | 1,253,862 (+1.1%) | 1,344,929 (+8.4%) | 1,302,127 (+5.0%) | not built |
| wasm ledger, no `--opt` (base 868,142) | 994,482 (+14.6%) | 974,540 (+12.3%) | 971,813 (+11.9%) | not built |
| wasm ledger, `--opt=size` (base 722,893) | 822,593 (+13.8%) | 802,991 (+11.1%) | 799,812 (+10.6%) | not built |
| Compile risks | Q4 and #12482: solved with a nominal `Reply` and heads by hand (proved) | None found | Q8, Q9, Q10 pass. A row inside the payload (`[Infra([TimedOut, ..i]), ..e]`) does not compile (Q10): a combinator adds `Infra([TimedOut])` as its own row tag, and the payloads merge at the use site | As G1a |

Notes on the sizes:

| Item | Value |
| --- | --- |
| The G prototype | Generated wrappers (`gen_g.py`): `x!` is `x_flat!(...).map_err(nest_k)`. A real G writes the nested tags in the bodies |
| The control G0 | The same wrappers with the flat errors, and the example with no change: web 1,351,519 (no `--opt`), 1,146,472 (`--opt=size`); ledger 864,353, 718,728. The wrappers alone make web 7% to 8% smaller than the base, so the layout moves the size by more than the error design |
| G against its control | web +14% (no `--opt`), +14% (`--opt=size`); ledger +12%, +11% |
| The C prototype | `RpcX.call!` wraps the `call!` of the platform (`RpcX.from_wire`). A real C parses the reply once |
| Option B (old base `6e3c461`) | web 1,798,425 (+24%), ledger 1,009,547 (+13%), no `--opt` |

### Recommendation: G1a

G1a is the cleanest end state for the app code:

| Reason | Evidence |
| --- | --- |
| The handler writes domain errors plainly and uses `?` on each platform call | `option-g/LotRoom.roc` |
| The caller has one shape: `Infra(..)` for this hop, `Remote(Infra(..))` for the callee, `Remote(<domain>)` | `option-g/web.roc` |
| Each platform function keeps its precise error type. The payloads merge at `?` and close at the Rpc type | Q8 |
| The re-match of `NotFound` (N6) gets shorter: 1 arm in place of 1 arm for each infrastructure tag | `load_state!`, `open!` |
| `Rpc.on`, `Reply` and the wire do not change. No hand-written reply head is added | `platform-g/` has the old `Rpc.on` |
| The fewest app lines changed | 18 against 30 (C) and 23 (E) |

Costs and limits of G1a:

| Cost | Size |
| --- | --- |
| A breaking change for each app, also outside Rpc: each match on an infrastructure tag gets `Infra(..)` | Auction: 2 arms outside Rpc. Conformance: 229 uses of infrastructure tags in 27 files. MODULES.md: 216 lines |
| Wasm | Web: +4% against C (`--opt=size`). Ledger: 3% smaller than C |
| Some tags are not always infrastructure: `BadData` of `Request.json!` is a bad request (400), `Constraint` can be a domain conflict (409), `TooLarge` of `accept_with!` is a bad request | A decision for each function (open question 1). The prototype nests only Object, Kv, D1, R2 and Service |

If the breaking change outside Rpc is not acceptable, use C (section 7). It has the smallest web wasm and changes only Rpc code.

## 3. What the platform gives today

All infrastructure errors of the platform have one of 4 payload forms, all CBOR data: `Io.Thrown` (`{ name : Str, message : Str }`), `Str`, `Sql.Constraint` (a record with a closed tag), or none.

| Group | Tags (count of uses in `platform/*.roc`) |
| --- | --- |
| Storage of an object | `StorageErr(Io.Thrown)` (16), `SqlErr(Io.Thrown)` (8) |
| SQL of D1 and of an object | `Constraint(Sql.Constraint)` (62), `D1Err(Io.Thrown)` (55) |
| Other bindings | `KvErr` (32), `R2Err` (31), `CacheErr` (7), `QueueErr` (9), `AiErr` (7), `VectorizeErr` (16), `WorkflowsErr` (20), `EmailErr` (12), `AnalyticsErr` (1), `AssetsErr` (2), `SecretsStoreErr` (2), `LimitErr` (2), all `(Io.Thrown)` |
| Calls | `ObjectErr` (4), `ServiceErr` (2), `RpcErr` (5), `HttpErr` (10), `Network` (10), `SocketErr` (17), all `(Io.Thrown)` |
| Data and limits | `BadData(Str)` (109), `InvalidJson(Str)` (8), `BodyErr(Io.Thrown)` (23), `CryptoErr(Io.Thrown)` (22), `MissingEnv(Str)` (3), `TooLarge`, `TimedOut` |

These 29 tags are `Rpc.Infra`. The user decided: `RpcErr`, `TimedOut`, `MissingEnv` and `InvalidJson` are in it. No two of the tags have the same name with different payloads. The domain-like tags (`NotFound`, `Closed`, `PreconditionFailed`, `NotUpgrade`) are not in it.

## 4. Probes

| File | Question | Result |
| --- | --- | --- |
| `q1_extend.roc` | Option B: an alias with a row variable `Infra(e) : [..., ..e]`, given a closed union | Works |
| `q2_fault.roc` | Option C: `Fault(err) : [Fail(err), <infra tags>]`, an `on` that returns a lambda, a split into `Remote(err)` and `Infra(Infra)` | Works |
| `q3_narrow.roc` | Option D: can a `match` take tags out of a flat open union and give the rest as `..e`? | No (`type mismatch`) |
| `q4_codec.roc` | A derived CBOR codec for `Fail(e)`, `e` a constrained type variable, in generic code | No: `missing method encoder_for` |
| `q5_empty_row.roc` | A derived codec for `InfraOr([])` (a row variable closed with `[]`) | No, but the same union written out has one. Compiler defect candidate |
| `q6_widen.roc`, `q6_widen_fail.roc` | Can a parameter of the closed `Infra` be a `Fault(err)` with no match? | No: a match is necessary. Option C `forward` works with it |
| `q7_wrap_infra.roc` | Option E: domain flat, `? Infra` at each call | Works |
| `q8_nested.roc` | Option G: G1a (precise closed payload), G1b (payload with an open row), G2 (whole `Infra`). `?` of two functions, a re-raise `Err(Infra(i)) => Err(Infra(i))`, a helper with no annotation, an exhaustive match outside Rpc | All work. G1a needs no row variable: the closed payload of a function result widens at `?` and at a re-raise |
| `q9_forward_g.roc` | Option G `forward` for a nested call: the same domain (`forward(\|e\| e)`) and a mapped domain | Works |
| `q10_row_infra.roc`, `q10_fail.roc` | Option G: a combinator that adds `TimedOut` with a row (`Io.timeout`) | `[Infra([TimedOut]), ..e]` works, also when `e` has its own `Infra(..)`: the payloads merge, and a match with no `_` is exhaustive. A row inside the payload does not compile (3 errors) |
| `option-b/` | The auction with option B (old base) | Builds |
| `option-c/` | The auction with option C (`RpcX.roc`: the proposal as an app module) | Builds. 5 `expect` tests of the wire bytes pass (a broken `infra_head` fails 2) |
| `option-e/` | The auction with option E (`RpcE.roc`: the alias only) | Builds |
| `option-g/` | The auction with option G1a on `platform-g/` | Builds |
| `option-g0/` | The control: the example with no change on `platform-g0/` | Builds |
| `gen_g.py`, `make-platform-g.sh` | Make `platform-g/` and `platform-g0/`: a copy of `platform/` with G1a in Object, Kv, D1, R2, Service (79 functions, 29 error unions) and `Rpc.Infra`. Not in git | `roc check` of `platform-g/main.roc`: no errors |

## 5. Options

| Option | Status |
| --- | --- |
| A. Today: list all tags in `err` | The problem |
| B. Flat row alias `Rpc.InfraOr([NotOpen, ...])` | Works. No single caller arm for the infrastructure (Q3), name clashes are silent, Q5, web +24% |
| C. Domain in `Fail`, split for the caller | Works. Section 7 |
| D. A flat handler error, `on` splits it | Not possible (Q3) |
| E. Domain flat, `? Infra` at each call | Works. Per-call code |
| F. Infrastructure errors as text | Rejected by the user |
| G1a. Each platform function gives `Infra([its own tags])` | Works. Recommended. Section 6 |
| G1b. As G1a, with an open row in the payload | Works for plain functions (Q8). Not necessary: G1a widens with no row. A row inside the payload fails in a generic combinator (Q10) |
| G2. Each platform function gives `Infra(Rpc.Infra)` | Works (Q8). Loses the precise type of each function |

## 6. Option G1a in detail

### 6.1 Proposed signatures

```roc
# platform/Rpc.roc
Rpc(arg, ret, err) :: { name : Str }.{
	method, name, on, on_worker, reply_of, entrypoint     # no change: the handler err is closed, e.g. [NotOpen, Infra(Rpc.Infra)]

	## New. The infrastructure errors of the platform: one closed union.
	Infra : [
		StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), D1Err(Io.Thrown), KvErr(Io.Thrown),
		R2Err(Io.Thrown), CacheErr(Io.Thrown), QueueErr(Io.Thrown), ObjectErr(Io.Thrown), ServiceErr(Io.Thrown),
		RpcErr(Io.Thrown), HttpErr(Io.Thrown), Network(Io.Thrown), SocketErr(Io.Thrown), BodyErr(Io.Thrown),
		CryptoErr(Io.Thrown), AiErr(Io.Thrown), VectorizeErr(Io.Thrown), WorkflowsErr(Io.Thrown), EmailErr(Io.Thrown),
		AnalyticsErr(Io.Thrown), AssetsErr(Io.Thrown), SecretsStoreErr(Io.Thrown), LimitErr(Io.Thrown),
		BadData(Str), InvalidJson(Str), MissingEnv(Str), TooLarge, TimedOut,
	]

	## New. A nested call in a handler, for `?`: the errors of this hop stay in `Infra`, `f` maps the error of the
	## callee (`forward(|e| e)` when both have the same type). q9_forward_g.roc.
	forward : (err -> [Infra(Rpc.Infra), ..e]) -> ([Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote(err)] -> [Infra(Rpc.Infra), ..e])

	NoErr                                                 # no change: a method with no error at all
}

# The callers (and the twins `call` in platform/Remote.roc)
Object.call!  : Object, Rpc(arg, ret, err), arg => Try(ret, [Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote(err)]) where [...]
Service.call! : Service, Rpc(arg, ret, err), arg => Try(ret, [Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote(err)]) where [...]

# Each function: its own tags in Infra (examples from platform-g/)
Object.Cell.get! : Object.Cell(a), Object.Self => Try(a, [NotFound, Infra([BadData(Str), StorageErr(Io.Thrown)])])
Object.Cell.set! : Object.Cell(a), Object.Self, a => Try({}, [Infra([StorageErr(Io.Thrown)])])
Object.Self.sql! : Object.Self, Str, params => Try(rows, [Infra([SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge])]) where [...]
Kv.Cell.get!     : Kv.Cell(a) => Try(a, [NotFound, Infra([KvErr(Io.Thrown), BadData(Str), TooLarge])])
D1.run!          : D1, Str, params => Try(Sql.Info, [Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint)])]) where [...]
Env.secret!      : Str => Try(Secret, [Infra([MissingEnv(Str)])])
Io.timeout       : Io(a, e), U64 -> Io(a, [Infra([TimedOut]), ..e])     # q10_row_infra.roc
```

### 6.2 The auction, before and after

`Gavel.roc`:

```roc
# Before
RoomErr : [NotOpen, AlreadyOpen, StillOpen, StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]
SettleErr : [D1Err(Io.Thrown), Constraint(Sql.Constraint), KvErr(Io.Thrown), BadData(Str), TooLarge]

# After
RoomErr : [NotOpen, AlreadyOpen, StillOpen, Infra(Rpc.Infra)]
SettleErr : [Infra(Rpc.Infra)]
```

`LotRoom.roc` (`open!`, an Rpc handler; `load_state!` is the same change):

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

# After
open! : Object.Self, Gavel.Lot => Try({}, Gavel.RoomErr)
open! = |self, lot| match state_cell.get!(self) {
	Ok(_) => Err(AlreadyOpen)
	Err(NotFound) => {
		state_cell.set!(self, { status: Open, ... })?
		self.set_alarm_at!(lot.close_ms)?
		Ok({})
	}
	Err(Infra(i)) => Err(Infra(i))
}
```

Code outside Rpc (`LotRoom.roc` `fetch!`, `web.roc`):

```roc
		Err(TooLarge) => Ok(Response.from_status(400))           # before
		Err(Infra(TooLarge)) => Ok(Response.from_status(400))    # after

	Constraint(_) => Response.from_text(409, "the lot exists")           # before
	Infra(Constraint(_)) => Response.from_text(409, "the lot exists")    # after
```

`web.roc` `error_response!`:

```roc
# After
error_response! : [NotFound, Unauthorized, BadRequest(Str), BadData(Str), Infra(Rpc.Infra), Remote(Gavel.RoomErr), ..] => Response
error_response! = |e| match e {
	NotFound => Response.from_text(404, "not found")
	Remote(NotOpen) => Response.from_text(404, "the lot room is not open")
	Remote(AlreadyOpen) => Response.from_text(409, "the lot room is open")
	Remote(StillOpen) => Response.from_text(409, "the lot is still open")
	Remote(Infra(StorageErr(_))) | Remote(Infra(SqlErr(_))) => {
		Log.error!("lot room storage failed", Str.inspect(e))
		Response.from_text(503, "the lot room is not available")
	}
	Unauthorized => Response.from_text(401, "admin token needed")
	BadRequest(msg) => Response.from_text(400, msg)
	BadData(msg) => Response.from_text(400, msg)              # Request.json! (not nested in the prototype)
	Infra(Constraint(_)) => Response.from_text(409, "the lot exists")
	_ => {
		Log.error!("request failed", Str.inspect(e))
		Response.from_text(500, "server error")
	}
}
```

`ledger.roc`: no change. `settle_due!` keeps `Try({ settled : U32 }, Gavel.SettleErr)`, and each `?` fits. A nested call that gives its errors to the caller: `closeout = lot_rooms.named(id).call!(Gavel.close_out, {}) ? Rpc.forward(|e| e)`.

### 6.3 Migration list

| File | Change |
| --- | --- |
| `platform/*.roc` | Each public function with an infrastructure tag: the nested type, and the bodies give `Infra(..)` (294 signature lines). `Io.timeout`, `Io.timeout_at`: `[Infra([TimedOut]), ..e]` |
| `platform/Rpc.roc` | `Infra`, `forward`. `on`, `Reply`, `reply_of`: no change |
| `platform/Object.roc`, `platform/Service.roc`, `platform/Remote.roc` | `call!` and `call`: `[Infra([RpcErr(Io.Thrown), BadData(Str)]), Remote(err)]` |
| `bench/platform/` | The same (copy of the platform) |
| `MODULES.md`, `API.md` | Each signature with an infrastructure tag (216 lines in MODULES.md). MODULES.md 8: the caller shape, `forward` |
| `PLAN.md` | A row in the 8h table |
| `conformance/` | Each route and check that matches an infrastructure tag (229 uses in 27 files). `must-not-compile`: a flat infrastructure tag in an Rpc `err` does not compile. `reverts.mjs`: entries for `forward` and for some `nest` arms |
| `examples/` | Each match on an infrastructure tag. The auction: the diff of `option-g/` (18 lines) |
| `examples/auction/REVIEW.md` | N5: done |

## 7. Option C in detail (the alternative)

C changes only Rpc code. The handler error is `Rpc.Fault(err) : [Fail(err), <the 29 tags of Rpc.Infra>]`.

```roc
Fault(err) : [Fail(err), <the 29 tags of Infra>]
on        : Rpc(arg, ret, err), (self, arg => Try(ret, Rpc.Fault(err))) -> Rpc.Handler(self) where [...]
on_worker : Rpc(arg, ret, err), (arg => Try(ret, Rpc.Fault(err))) -> Rpc.Handler({}) where [...]
reply_of  : List(U8) -> Try(ret, [BadData(Str), Remote(err), Infra(Rpc.Infra)]) where [...]
forward   : Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err), Infra(Rpc.Infra)]), (err -> e2) -> Try(ret, Rpc.Fault(e2))
Reply(ret, err) := [Ok(ret), Err(err), Infra(Rpc.Infra)]     # derived parser; on writes the heads by hand
infra_head = [0xa1, 0x65, 0x49, 0x6e, 0x66, 0x72, 0x61]      # {"Infra": ...}
call!     : ... => Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err), Infra(Rpc.Infra)])
```

| Handler result | Bytes | Caller gets |
| --- | --- | --- |
| `Ok(v)` | `{"Ok": v}` | `Ok(v)` |
| `Err(Fail(e))` | `{"Err": e}` (as today) | `Err(Remote(e))` |
| `Err(StorageErr(t))` | `{"Infra": {"StorageErr": t}}` (new) | `Err(Infra(StorageErr(t)))` |

Two findings set the shape of C: Q4 (no generic codec for `[Fail(e), ...]`, so `Reply` stays nominal) and roc-lang/roc#12482 (no generic nominal encode in the lambda of `on`, so the heads are bytes). `option-c/RpcX.roc` implements both and the build has no crash.

The app code of C: `Err(Fail(AlreadyOpen))` at each domain error, and a helper that both an Rpc handler and other code use gives `Fail(X)` (`on_message!` matches `Err(Fail(NotOpen)) | Err(NotOpen)`). The caller: `Remote(NotOpen)`, `Infra(StorageErr(_))`. Migration: `platform/Rpc.roc`, the `call!` of Object, Service, Remote, `bench/platform/`, MODULES.md 8, the Rpc conformance routes and checks, `reverts.mjs` line 629, the auction (30 lines).

## 8. Open questions

| # | Question | Default of this study |
| --- | --- | --- |
| 1 | G: is a tag nested for each module or for each function? `BadData` of `Request.json!` is a bad request, `Constraint` of an insert can be a domain conflict, `TooLarge` of `accept_with!` is a bad request | For each function. Nest the errors of storage, bindings and calls. Keep the request-parse errors of `Request` flat |
| 2 | G: is the breaking change outside Rpc acceptable (all apps, conformance, MODULES.md)? | Yes, if G is chosen. Else C |
| 3 | Names: `Rpc.Infra`, the tag `Infra` | As written |
| 4 | Q4 and Q5 are compiler limits. Report them upstream? | Yes, Q5 first |
| 5 | A caller `_` arm still catches a new domain tag. Show an exhaustive `Remote(r) => room_response(r)` form in MODULES.md 8? | Yes, one sentence |
