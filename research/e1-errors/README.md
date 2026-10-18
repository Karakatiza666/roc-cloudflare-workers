# Per-handler errors and typed RPC errors (step 8h, compiler probes)

Compiler: `bench/get-roc.sh`. Run from the submodule root: `$ROC check research/e1-errors/<file>`.

| File | Result | Shows |
| --- | --- | --- |
| `one_field.roc` | prints `5 5` (`$ROC <file>`) | `{ a }` with one field is a block. `{ a, }` and `{ a: a }` are records. |
| `two_errors.roc` | no errors | `fetch!` with `[]` and `scheduled!` with `[UnknownCron(Str)]` in one `Worker.new`. |
| `foreign_tag.roc` | 1 error (type mismatch) | A handler that gives `Busy` for `Rpc({}, U64, [StillOpen])`. With `StillOpen` it compiles. |
| `rpc_min.roc` | no errors | Typed error on both sides: `match ... Err(Remote(StillOpen))`. |
| `rpc_obj.roc`, `rpc_obj2.roc` | no errors | The same on a Durable Object class, with `[Busy]` and with `Rpc.NoErr`. |
| `rpc_empty.roc` | 3 errors | `[]` has no derived `parser_for` / `encoder_for`. |
| `no_err.roc` | no errors | A nominal `[]` with a hand-written codec (the form of `Rpc.NoErr`). |
| `mod/app.roc` | no errors | `on` in a type module of the app. With `Cbor.encode(Reply.Ok(r))` in `on` (nested `Rpc.Reply` or top-level `Reply`), the compiler crashes (SIGSEGV). So `on` writes the head bytes by hand. |

`roc test platform/main.roc` also traps (SIGTRAP) on `expect ok_head.concat(Cbor.encode(3.U64)) == Cbor.encode(Reply.Ok(3.U64))` in `platform/Rpc.roc`, so that check is not in the platform tests. The bytes match `research/rpc-err-sql-params/enc.roc`.
