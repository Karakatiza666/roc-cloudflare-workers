# Typed RPC errors and SQL parameters (compiler probes, 2026-10-18)

Compiler: `bench/get-roc.sh` (nightly-2026-10-12-2664a27). Package: roc-cbor 0.1.0. Platform: `../../platform/main.roc` (not changed).

Run from the submodule root:

```sh
ROC=$(bench/get-roc.sh); export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
$ROC check research/rpc-err-sql-params/q1_sig.roc    # 2 expected errors (f3, f4)
$ROC check research/rpc-err-sql-params/q1_ctrl.roc   # 2 expected errors (c3, b3)
$ROC check research/rpc-err-sql-params/q1_wire.roc   # 1 expected error (decode_a)
$ROC check research/rpc-err-sql-params/q1_handler.roc # 1 expected error (bad)
$ROC test  research/rpc-err-sql-params/enc.roc       # dbg prints the bytes
$ROC test  research/rpc-err-sql-params/enc2.roc
$ROC test  research/rpc-err-sql-params/enc3.roc
```

| File | Shows |
| --- | --- |
| `q1_row.roc` | First try of the row form with a body. Fails (see report). |
| `q1_sig.roc` | Row form `[RpcErr, BadData, ..err]`: the signature is accepted. Use sites: `match` and inferred `?` work, `?` into a declared union does not. |
| `q1_ctrl.roc` | Control (today closed result) and form B (`Remote(err)`). |
| `q1_wire.roc` | Generic reply type `Reply(ret, err)` with derived codec. Form B body compiles. Row form body does not. |
| `q1_handler.roc` | Handler type `self, arg => Try(ret, err)`. A tag outside `err` does not compile. |
| `enc.roc`, `enc2.roc`, `enc3.roc` | CBOR bytes of tags, tuples, lists, bytes, NULL, optional fields. |
