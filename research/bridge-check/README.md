# Bridge check: where `await!` and `call!` can live (PLAN.md 8a)

API.md 6.4 named `Js.await!(program)` and `Js.call!(program)`. The hosted functions take a `Js`, so the module of
the hosted functions (`Host`) imports `Js`. A `Js.await!` must call `Host.await!`, so `Js` must import `Host`.

| Try | Result (nightly-2026-10-12-2664a27) |
| --- | --- |
| `cycle/`: `Js.roc` imports `Host`, `Host.roc` imports `Js` | `roc check cycle/app.roc`: "import cycle detected ... Cycles between modules are not allowed." |

So 8a builds them as `Io.await!(ops)` and `Io.call!(ops)` (`platform/Io.roc`): `Io` imports `Js` and `Host`, and
nothing imports `Io`. Run: `$ROC check research/bridge-check/cycle/app.roc` (exit 1 is the expected result).
