# A `{}` answer of an Rpc crashes `roc build` (examples/auction/REVIEW.md N1)

Date: 2026-10-20. Pinned compiler: `bench/get-roc.sh` (nightly-2026-10-12-2664a27).

## Result

| Item | Finding |
| --- | --- |
| Smallest trigger | The derived parser of a tag union whose payload is `{}`: `Json.parse` into `Try([W({})], _)` (`v5.roc`). No platform and no package. `roc check` passes; `roc build` and `roc <file>` crash (SIGSEGV). |
| Not a trigger | A `{}` at the top (`v2.roc`), a `{}` record field (`v7.roc`), the encoder of `W({})` (`v6.roc`), a one-field record payload (`v8.roc`), a `Str` payload (`v5_str.roc`). |
| In the platform | `Rpc.reply_of` parsed `Reply(ret, err) := [Ok(ret), Err(err)]`. With `ret = {}` that is the trigger (`m1.roc`). |
| nightly-2026-10-12-2664a27 (pinned) | crash |
| nightly-2026-10-18-1df370f | crash |
| nightly-2026-10-19-601b54c | fixed: each file prints `True` |
| Upstream | No new issue: the bug is fixed upstream. The fix is in the range 1df370f..601b54c, most likely commit 09061cd45 "Register payload records for a tag-union spec with no labels" (PR roc-lang/roc#12424, branch `issue-12376-spec-entry-records`, for https://github.com/roc-lang/roc/issues/12376). |
| Workaround | `Rpc.reply_of` read the head (`ok_head`, `err_head`) by hand and parsed only the value as `ret` or `err`. The public API did not change. |
| Removed | The pin moved to nightly-2026-10-19-601b54c. `Rpc.reply_of` parses the derived `Reply(ret, err)` again. `Rpc.on` still writes the heads by hand: `Cbor.encode(Reply.Ok(r))` in `on` still crashes the compiler on 10-19 when a type module of the app uses `on` (`research/e1-errors/mod`). |

## Files

| File | Shows | Pinned nightly |
| --- | --- | --- |
| `v5.roc` | Smallest: `Json.parse` into `[W({})]` | crash |
| `v5_str.roc` | Control: `[W(Str)]` | `True` |
| `v3.roc` | `[Ok({}), Err([A])]` | crash |
| `v1.roc`, `v4.roc` | A nominal tag union with `parser_for : _` and a `{}` payload | crash |
| `plain_json.roc` | The old `reply_of` shape, generic, on `Json` | crash |
| `plain_json_str.roc` | The same with a `Str` answer | `ok x` |
| `v2.roc`, `v6.roc`, `v7.roc`, `v8.roc` | Not triggers (see above) | `True` / `{"W":{}}` |
| `m1.roc` | The auction shape on the platform: `rooms.named("x").call!(open, "lot")?` with `open : Rpc(Str, {}, [AlreadyOpen])` | crash before the workaround, builds after |
| `m1_str.roc` | Control: a `Str` answer | builds |

## Run

From the submodule root:

```sh
ROC=$(bench/get-roc.sh); export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
(cd research/rpc-unit-crash && for f in v5 v5_str v3 plain_json; do $ROC $f.roc; done)
$ROC build --target=wasm32 --no-cache --output=/tmp/m1.wasm research/rpc-unit-crash/m1.roc
```

## Tests

| Test | Where |
| --- | --- |
| `{}` answer, `Ok({})` and `Err(Remote(AlreadyOpen))`, on the default entry point, the entry point `Admin` and the object `Counter` | `conformance/checks/rpcerr.mjs`, method `RpcMethods.open_lot` |
| The auction shape (`?` on the `call!`) | the same file, route `/rpcerr/obj/unit_try` |
| The revert (the old `reply_of` with `Reply`): `roc build` of the conformance app crashes | `conformance/reverts.mjs`, `8h N1: ...`, test `conformance build` |
