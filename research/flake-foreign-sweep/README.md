# Flake: a sweep of another request context does not end an Init wait

## Problem

The conformance check `objects init! past the Init deadline is cancelled` failed about 1 run in 12 with `took ~6010 ms`.

| Time | What occurs |
| --- | --- |
| 0 ms | `Slow.init!` starts a sleep of 6 s. The Init deadline is 1000 ms (`initMs`). |
| 1000 to 1050 ms | A request of another context (another object, an alarm) calls `tasks.sweep()` (`js/runner.js` `run`). It cancels the Init task and resolves its wake. |
| 1050 ms and each 100 ms | The timer of `objectInit` (`js/index.js`) sweeps. The task is cancelled already, so it does nothing. |
| 6000 ms | The sleep ends. Only now the race in `js_await` (`js/bridge.js`) sees the wake. |

Cause: workerd keeps a promise resolve from another request context until the context of the Durable Object has I/O. A resolve from the own context ends the wait at once.

## Fix

| File | Change |
| --- | --- |
| `js/tasks.js` `waitStart` | Makes a second promise `t.ownWoken` (resolver `t.wakeOwn`). |
| `js/tasks.js` `sweep(own)` | For the task with `hooks === own`: when it is cancelled, call `t.wakeOwn()`. The cancel, its log line and the counts stay the same (once). |
| `js/bridge.js` `js_await` | The race is `[running, cancelled, t.ownWoken]`. |
| `js/index.js` `watch` | The timer of each object task (`objectInit` has no timer of its own now) calls `sweep(hooks)` with the hooks of the task. |

## Files

| File | Use |
| --- | --- |
| `zzrepro.mjs` | Starts `/objects/slow`, sends another request at 1010, 1020, 1030, 1040 ms. Before the fix: 1020 to 1040 take about 6015 ms. After: about 1060 ms. |
| `zzfetch.mjs` | Probe: the same for a Fetch task of the Worker (`taskDeadlineMs` 1000). The sweep of another request ends it at once (1223 ms), also before the fix. The problem is in a Durable Object context only. |

Run (from the repo root, after `bench/build.sh`):

```
cp research/flake-foreign-sweep/zzrepro.mjs conformance/checks/ && node conformance/run.mjs bench/out/conformance.wasm "ZZ foreign sweep"; rm conformance/checks/zzrepro.mjs
```

## Other kinds, and the cost (2026-10-22, step "Exact deadlines")

Question: does a sweep from another context also end a wait late for the other object tasks (fetch, Rpc, alarm)?

| Case (deadline 500 ms, sleep 2500 ms) | Before the change | After |
| --- | --- | --- |
| ObjectFetch, a request of the Worker sweeps at 510 to 540 ms | 519 to 548 ms (the wake works) | 526 to 565 ms |
| Rpc, the same | 518 to 549 ms | 536 to 563 ms |
| Alarm, the same (from the start of the alarm task) | 526 to 543 ms | 537 to 559 ms |
| ObjectFetch, no other request | 2508 ms (not cut at the deadline) | 557 ms |
| Rpc, no other request | 2512 ms | 560 ms |
| Alarm, no other request | 2503 ms | 539 ms |
| Worker fetch, no other request (`zzfetch.mjs`) | 2579 ms | 2579 ms (no timer for a Worker task) |

So the held wake is seen for `Init` only (the cause is not known: `Init` is the one task that runs in a callback of `blockConcurrencyWhile`, the others run in a request, an Rpc call or an alarm). For the other kinds the gap was a deadline that no request sweeps. The timer of each object task (`watch`, `js/index.js`) closes it, and it also wakes the wait from the own context.

Cost (`zzcost.mjs`, 400 requests, Miniflare, 3 runs each):

| Request | `setTimeout` before | after | `clearTimeout` before | after | Time per request before | after |
| --- | --- | --- | --- | --- | --- | --- |
| Worker fetch, no object | 0 | 0 | 0 | 0 | 1.8 to 2.3 ms | 1.8 to 2.1 ms |
| Object fetch! | 0 | 1 | 0 | 1 | 2.6 to 2.9 ms | 2.4 to 3.2 ms |
| Object Rpc | 0 | 1 | 0 | 1 | 1.8 to 2.1 ms | 1.6 to 2.4 ms |

A pair `setTimeout` and `clearTimeout` costs 0.3 us in Node (1,000,000 pairs). No micro benchmark of tasks or deadlines exists in `bench/` (`bench/deadline-test.mjs` is a test).

Files: `zzobject.mjs` (the table above, needs the routes `/sleep`, `/alarm_nap` and the Rpc method `nap` of `Counter` in `conformance/`), `zzcost.mjs`.
