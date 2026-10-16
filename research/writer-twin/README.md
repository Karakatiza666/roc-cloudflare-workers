# A put of a `Body.writer!` stream with the public API (PLAN.md 8c, RO1, 2026-10-16)

`fixed.mjs`: does an R2 put of a `FixedLengthStream` end when the stream has its length, with no `close`?

| Case | Result (Miniflare 5.20261012.0-beta) |
| --- | --- |
| Write all 11 bytes, no `close` | The put does not end (`timeout` after 1.5 s) |
| Write, then `close` | `put 11, written` |

So a branch of `Io.both!` or `Io.race!` with only a `write` cannot feed the put: the `close` must come after the write, and a program of one branch has no sequence of two `Io` values. The route of RC13 (`conformance/R2Routes.roc`, `put_stream!`) does `Io.start!` of the `write` and `write_text` twins (each `write` is queued at once and waits until the put reads it), then `close!` (queued after the writes), then `put_with!`.

Run: `node research/writer-twin/fixed.mjs`.
