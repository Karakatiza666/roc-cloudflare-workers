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
| `js/index.js` `objectInit` | The timer calls `sweep(hooks)` with the hooks of the Init task. |

## Files

| File | Use |
| --- | --- |
| `zzrepro.mjs` | Starts `/objects/slow`, sends another request at 1010, 1020, 1030, 1040 ms. Before the fix: 1020 to 1040 take about 6015 ms. After: about 1060 ms. |
| `zzfetch.mjs` | Probe: the same for a Fetch task of the Worker (`taskDeadlineMs` 1000). The sweep of another request ends it at once (1223 ms), also before the fix. The problem is in a Durable Object context only. |

Run (from the repo root, after `bench/build.sh`):

```
cp research/flake-foreign-sweep/zzrepro.mjs conformance/checks/ && node conformance/run.mjs bench/out/conformance.wasm "ZZ foreign sweep"; rm conformance/checks/zzrepro.mjs
```
