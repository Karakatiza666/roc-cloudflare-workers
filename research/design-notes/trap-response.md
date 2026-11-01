# Design note: the response of a trap (`on_trap`)

State: accepted by talon-04 (2026-11-02), with the decisions of section 7. Plan: section 8 (release 0.0.3). No platform code is changed by this note.

Rule ids: `API.md` has no family for the trap response. This note proposes the family `TR` (TR1 to TR12, section 5). It cites `API.md` 10.1 (events, the rule for a new optional field), 10.2 (deadlines), `AG1`, `J1` to `J7` (the values that cross), `AQ10` (the manifest), `PLAN.md` problem 12 (one instance per isolate, alarm), `M1`, `M7` (shed), `3b`, `3c` (cancel), `5b`, `5c` (CPU), `MODULES.md` 3 (bindings, crons in the manifest).

## 1. Problem

A `crash` or a trap in a `fetch` handler gives `500`, body `trap RuntimeError: unreachable`, `Content-Type: text/plain;charset=UTF-8` (the default of `new Response(text)`). OOM, a shed, a cancel give `503` with a `trap ...` text. An app that must always answer in its own form (the registry: `application/problem+json`, R-AP21, R-AP48) cannot do it for these cases. The text also shows an internal detail (the wasm error) to each client.

The app cannot run Roc code to answer: after a trap the instance may be damaged (`PLAN.md` problem 12), there is one instance per isolate, and other tasks of the instance may wait in the task table.

## 2. What the shim does today

From `js/index.js` (`Handler.fetch`, `fetchLike`) and `js/runner.js` (`runOwned`, `cleanTrap`, `alarm`, `cancelled`, `shedMem`):

| Cause | Where (runner result) | Status | Body today | Instance |
| --- | --- | --- | --- | --- |
| `crash` (Roc `crash`, `unreachable`) | clean trap, `crash` text from the host log | 500 | `trap RuntimeError: unreachable` | stays |
| Other clean trap (a clean stack overflow, another `RuntimeError`) | `cleanTrap`, no `crash` | 500 | `trap <error>` | stays |
| Alarm: unclean trap, sum mismatch, bad block, trap in an export after the task | `runner.alarm`, `alarm: 'trap' \| 'sum' \| 'block'` | 503 | `trap <error>` or `trap alarm: sum` | global check (12c), replaced if it fails |
| CPU signal (`5b`) | `cleanTrap`, `cause: 'cpu'` | 503 | `trap cpu limit` | stays |
| Out of memory (`M6`): a denied grow, or no request block | `cause: 'oom'` | 503 | `trap out of memory` or `trap out of memory: request block` | stays |
| Shed: all task slots in use | `shed: true` | 503 | `trap shed: all task slots are in use` | stays |
| Shed: memory pressure (`M7` step 2), old instance not collected (`M1`) | `shedMem`, `shed: true, reason` | 503 | `trap shed: <reason>` | stays |
| Cancel: deadline (`3b`, `10.2`) | `cancelled: 'deadline'` | 503 | `trap cancelled: deadline` | stays |
| Cancel: replace, heap check, terminated (`3c`, `M1`, `5c`) | `cancelled: 'replace' \| 'heap' \| 'terminated'` | 503 | `trap cancelled: <reason>` | new instance |
| Cancel: client gone (`request.signal`) | `cancelled: 'signal'` | 503 | `trap cancelled: signal` | stays (no client reads it) |
| The event cannot cross (`J1`, `J3`) | `encode` fail | 500 | `trap the event cannot cross: ...` | stays, no task in wasm |
| Not a trap: outcome `Failed` (an `Err` of `fetch!`) or `Unhandled` | `r.outcome` | 500 | empty | stays |

Not in the shim's hands:

| Case | What happens | In scope |
| --- | --- | --- |
| The isolate is stopped by workerd (CPU limit, `5c`) during the request | No JS runs; Workers sends its own error page | No |
| A trap after `Response.after` sent the response | Log line only | No: the response is gone |
| `Ctx.pass_through!` set | A throw; Workers sends the request to the origin | No: keep |
| A missing binding at the first event (`MODULES.md` 3, Node path) | A throw from `checkEnv` | No: a config fault |
| `scheduled`, `queue`, `email`, RPC, object alarm | A throw (retry, reject, `RpcErr`) | No: no HTTP response (open question O3 for RPC) |
| `fetch` of an object class and of a named entry point (`fetchLike`) | Same table as above | Yes |

No 503 today has `Retry-After`.

## 3. Requirements

| # | Requirement |
| --- | --- |
| Q1 | The app gives, at load, a fixed response (status, headers, body) for the cases of section 2 that are in scope. |
| Q2 | No Roc code runs to make it. No export of the instance is called, its memory is not read, no `ops` function of the app runs. The bytes are JS values made before the first event. |
| Q3 | A response per cause, with a default for the causes that the app does not name. |
| Q4 | Declared in Roc (`AG1`), in the manifest at load, as `bindings` and `crons` (`MODULES.md` 3). A bad value stops the load (`wrangler deploy` fails), as a bad binding does. |
| Q5 | Limits: a small body, few headers, a status that is an error. |
| Q6 | Headers that the shim must keep: `Retry-After` on a 503 of a shed or OOM. |
| Q7 | A new cause later must not break an app (`API.md` 10.1: a new optional field is not breaking; a new tag is). |
| Q8 | The log line, the counters (`stats.traps`, `oom`, `shed`, ...) and the instance rules do not change. Only the response changes. |
| Q9 | An app with no `on_trap` gets the response of today, byte for byte. |

## 4. Options

| Option | How | For | Against |
| --- | --- | --- | --- |
| D1: a fixed table in the manifest (`Worker.new({ on_trap })`) | The event `Manifest` answers with the table; the shim keeps it as JS values; `fetch` picks the entry by cause | No Roc at trap time. Typed in Roc. Checked at load. One place. | Fixed bytes only: no request id in the body |
| D2: a JS option `onTrap(info) => Response` in `worker.options.js` | JS code runs at trap time | Any form, a request id in the body | App code in JS (`AG1`). A JS throw or a slow function in the error path. Can read things that are not safe (a ref of the task). |
| D3: a Roc handler `on_trap!` on the same instance | Roc runs after the trap | Full Roc | Rejected: the instance may be damaged (problem 12), the task table, OOM |
| D4: a Roc handler on a fresh instance | A second instance for the answer | A clean heap | Rejected: about 2.4 MB more under OOM and pressure, a start at the worst time, global-scope rules of workerd |
| D5: a pure Roc function `cause -> response`, called for each cause at load | `Worker.new` calls it while it makes the manifest | Exhaustive `match`, no Roc at trap time | A closed cause union: a new cause is a new tag, which breaks an exhaustive `match` (Q7) |

## 5. Recommendation

D1, with a record of optional fields (one per cause) and a required `default`. A new cause later is a new optional field (Q7). The shim keeps the table from the manifest and makes each response from it with plain JS.

### 5.1 API sketch (Roc)

```roc
Worker.new : {
	fetch! ?: Request => Try(Response, e1),
	# ... the fields of today ...
	on_trap ?: Worker.OnTrap,          # new
} -> Worker

Worker.Fixed : { status : U16, headers : List(Header), body : List(U8) }

Worker.OnTrap : {
	default : Worker.Fixed,          # each cause in scope that has no field below
	crash ?: Worker.Fixed,           # a Roc crash, a clean trap
	alarm ?: Worker.Fixed,           # an unclean trap, a failed sum (problem 12)
	cpu ?: Worker.Fixed,             # the CPU signal (5b)
	oom ?: Worker.Fixed,             # out of memory (M6)
	shed ?: Worker.Fixed,            # task slots full, memory pressure (M7)
	deadline ?: Worker.Fixed,        # a task deadline (3b, API.md 10.2)
	cancelled ?: Worker.Fixed,       # replace, heap check, terminated (3c, M1)
	event ?: Worker.Fixed,           # the event cannot cross (J1, J3)
	failed ?: Worker.Fixed,          # outcome Failed or Unhandled (no trap)
}
```

Example (the registry form, accepted by talon-04): problem details (`application/problem+json`, R-AP21). `default` and `crash` give 500 with `{"type":"/errors/internal","title":"Internal error","status":500}`. `oom`, `shed`, `cpu` and `deadline` give 503 with `Retry-After`.

```roc
problem : U16, Str, List(Header) -> Worker.Fixed
problem = |status, title, extra| {
	status,
	headers: [Header.{ name: "content-type", value: "application/problem+json" }, Header.{ name: "cache-control", value: "no-store" }].concat(extra),
	body: Str.to_utf8("{\"type\":\"/errors/internal\",\"title\":\"${title}\",\"status\":${status.to_str()}}"),
}

internal = problem(500, "Internal error", [])
busy = problem(503, "Service unavailable", [Header.{ name: "retry-after", value: "1" }])

worker = Worker.new({
	fetch!: fetch!,
	on_trap: { default: internal, crash: internal, oom: busy, shed: busy, cpu: busy, deadline: busy },
})
```

Manifest (JS, `AQ10`): `traps: { default: { status, headers: [[name, value], ...], body: Uint8Array }, crash: {...}, ... }`. The body crosses as `Bytes` (`J2`).

Shim (sketch):

```js
// at load, in makeHandler, after checkManifest
const traps = manifest.traps;   // null when the app gives no on_trap
// at a trap in Handler.fetch and fetchLike (r: the runner result)
if (r.trap) return traps ? fixedResponse(traps, causeOf(r)) : new Response(`trap ${r.trap}`, { status: r.status ?? 500 });
```

### 5.2 Rules (proposed family TR)

| Id | Rule |
| --- | --- |
| TR1 | `on_trap` is optional. With no `on_trap` the responses are the ones of today (section 2), byte for byte. |
| TR2 | The cause of a runner result: `cancelled === 'deadline'` is `deadline`; another `cancelled` is `cancelled`; `shed` is `shed`; `cause === 'oom'` is `oom`; `cause === 'cpu'` is `cpu`; `alarm` is `alarm`; the encode fail is `event`; another trap is `crash`; an outcome `Failed` or `Unhandled` is `failed`. An absent field uses `default`. |
| TR3 | Scope: `fetch` of the default export, of an object class and of a named entry point. Not: after `Response.after`, with `Ctx.pass_through!`, and the kinds with no HTTP response (section 2). |
| TR4 | At trap time the shim calls no export of the instance, reads no wasm memory, runs no `ops` function and no app JS. It makes `new Response(copy of the body, { status, headers })` from the table: a new body each time (a body stream is read once). |
| TR5 | `checkManifest` checks the table at load, and a bad value is a throw that names the field: `status` 400 to 599 (O6); any `content-type`, also `application/problem+json`; at most 16 headers; a name is an HTTP token; a value has no CR, LF or NUL and is at most 1,024 bytes; the body is at most 4,096 bytes. |
| TR6 | Header names that the table cannot give (a throw at load): `content-length`, `transfer-encoding`, `connection`, `upgrade`, `keep-alive`, `set-cookie`. Workers sets the length from the body. |
| TR7 | `Retry-After`: on the causes `shed` and `oom` the shim adds `retry-after: <ceil(graceMs / 1000)>` (default 1) when the entry has none. The app can give another value. It cannot remove it. The same header is added to the responses of today for these causes (with TR1 this is the one change to an app with no `on_trap`; open question O2). |
| TR8 | The log line (`fetch: trap: <crash text>`) and the counters do not change. The crash text never goes to the response of a table entry. |
| TR9 | The table is read once, at load, from the event `Manifest` on its own instance (`manifestOf`). It is the same for each instance of the isolate, also after a replace (`M1`). |
| TR10 | An app with a raw `event!` (no `Worker` wrapper) answers `Unhandled` to `Manifest`, so it has no table (TR1). |
| TR11 | `sync` prints the table in its report (status and content type of each cause). |
| TR12 | A new cause is a new optional field of `Worker.OnTrap`: a minor release (`API.md` 10.1). |

## 6. Test plan

| Test | What | Where |
| --- | --- | --- |
| T1 | `roc test`: `Worker.manifest` of an app with `on_trap` gives the `traps` object (status, header pairs, `Bytes` body), and with no `on_trap` gives no `traps` key | `platform/Worker.roc` expects (as the manifest expects of today) |
| T2 | `checkManifest`: each limit of TR5, TR6 (status 200, 600, a body of 4,097 bytes, 17 headers, a value with `\r\n`, `content-length`, `set-cookie`) is a throw with the field name; 4,096 bytes and 16 headers pass | `js/test/` unit test (Node) |
| T3 | A route with `crash`: the status, headers and body of the `crash` entry; a second `crash` request gets the full body again (TR4, one body per response) | conformance, a second app `bench/app_trap.roc` (the conformance app keeps the responses of today, TR1) |
| T4 | Each cause with a different entry: `oom` (`isolateBytes` small), `shed` (task slots full), `deadline` (the clock skew of `checks/clock.mjs`), `cancelled` (a replace), `event` (a value that cannot cross), `failed` (an `Err`). Each response is its own entry; a cause with no field gets `default`. | conformance and `bench/` Node tests (OOM and shed are in `bench/budget-test.mjs` form) |
| T5 | No Roc after the trap: the counter of `handle` calls and of host exports called between the trap and the response is 0 (a counting wrapper of the exports in the bench host) | `bench/` |
| T6 | `Retry-After` (TR7): present on `shed` and `oom` with and without `on_trap`; the app value replaces it; absent on `crash` | conformance |
| T7 | The scope (TR3): an object `fetch` and an entry point `fetch` use the table; a trap after `Response.after` does not change the sent response; `pass_through!` still throws | conformance (`AfterRoutes.roc`, the object routes) |
| T8 | TR1: an app with no `on_trap` gives the bodies of today (the existing checks pass unchanged) | conformance, all |

Revert checks (the tricky ones): map `oom` to `crash` (T4 fails); give the same `Response` body object to each trap (T3 second request fails); skip the table in `fetchLike` (T7 fails); drop `Retry-After` when the entry has headers (T6 fails); call `drain` or a host export to make the response (T5 fails).

## 7. Decided questions (review by talon-04, 2026-11-02)

All questions are decided. The note was accepted with these answers.

| # | Question | Decision |
| --- | --- | --- |
| O1 | A request id in the body (problem `instance`, the `cf-ray` header)? | Later, after 0.0.3. A `{ray}` placeholder in the body is wanted: the shim fills it from the `cf-ray` request header (plain JS, no app code). |
| O2 | `Retry-After` on the 503 of today for an app with no `on_trap` (TR7) | As proposed: yes. A header is added; the status and body stay. |
| O3 | A fixed RPC error text for a trap? | As proposed: no. |
| O4 | Hide the wasm error text in the default body? | Yes, in a later release (not 0.0.3). The default body then has no wasm text; the detail stays in the log. |
| O5 | Status for `deadline` | Keep the 503 default. An app that wants another status gives the `deadline` entry. |
| O6 | Allow 400 to 499? | Yes: 400 to 599 (TR5). Not 1xx to 3xx. |
| O7 | The limits (4,096 bytes, 16 headers, 1,024 bytes a value) | As proposed. |

## 8. Implementation plan (release 0.0.3)

The steps are in order. Each step ends green before the next one starts. The revert checks are the tricky ones only.

| Step | Change | Tests | Revert checks |
| --- | --- | --- | --- |
| S1 | Roc: `Worker.Fixed`, `Worker.OnTrap`, the optional field `on_trap` of `Worker.new`, and the `traps` object of `Worker.manifest` (the body as `Bytes`). No `traps` key with no `on_trap`. | T1 (`roc test` expects in `platform/Worker.roc`), `roc check` of the examples (no change for them) | Encode the `crash` field under the name of `default` (the T1 expect of an app with both fails) |
| S2 | `js/manifest.js`: the check of TR5 and TR6, the table in the checked manifest (`traps`, or `null`) | T2 (Node unit test of `checkManifest`) | Accept a body of 4,097 bytes (off by one: the T2 limit row fails) |
| S3 | `js/index.js`: `causeOf(r)` (TR2), `fixedResponse` with a new body copy each time (TR4), in `Handler.fetch` and in `fetchLike` (TR3), and `Retry-After` for `shed` and `oom` (TR7), also with no `on_trap` | T3, T4, T6, T7, T8 in conformance with a second app `bench/app_trap.roc` (the registry example of 5.1), and the `bench/` Node tests for `oom` and `shed` | Give the same body object to each response (the second `crash` of T3 fails). Skip the table in `fetchLike` (T7 fails). Map `oom` to `crash` (T4 fails). |
| S4 | T5: a counting wrapper of the host exports in the bench host; 0 calls between the trap and the response | T5 | Call `drain` to make the response (T5 fails) |
| S5 | `sync` prints the table (TR11). Docs: `MODULES.md` 3 (`on_trap`, the cause table of section 2), the `TR` family in `API.md`, the release text (the new `Retry-After`, O2) | `cli-test.mjs`: the `sync` report of `app_trap.wasm` | None |

After 0.0.3: the registry adds `on_trap` with the form of 5.1 to `worker/main.roc`, and a W2 case for a `crash` route that checks the problem answer (slice 101 P3 is then closed).
