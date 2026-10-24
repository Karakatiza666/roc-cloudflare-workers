# Findings: storage and messaging

| # | Finding | How found | Error, short |
| --- | --- | --- | --- |
| S1 | `R2.Http` fields are optional (`?:`): read `meta.http.?content_type ?? "..."`, not `meta.http.content_type` | Serving an R2 object with its content type | "The content_type field is optional, but it is being accessed as if it is always present" |
| S2 | A D1 read that only goes to `Response.from_json` has no type: annotate the binding (`users : List(User)`) | `db.all!` straight into `from_json` | "type not determined ... encoder_for", at the `db.all!` call |
| S3 | A SQL parameter is a `Sql` tag, never a bare value: `[Text(name)]`, `[Int(id)]` | `db.run!(sql, ["ann"])` | "This string literal is being used where a non-string type is needed ... Sql" |
| S4 | `Sql.Int` holds an `I64`. A `U64` (from `U64.from_str`, a length) gives a mismatch that prints a structural union with `Int(U64)` | `[Int(id)]` with `id : U64` | "This argument has the type [Blob(List(U8)), Int(U64), ...] But run! needs ... Sql" |
| S5 | A row field read only with a method (`n.n.to_str()`) has no number type: the error is "missing parser_for" on `{ n: a }`, not "add an annotation" | `select count(*) as n` with no annotation | "A where clause requires the parser_for method ... { n: a } where [a.to_str ...]" |
| S6 | A `Body` is a tag, never a bare string: `files.put!(key, Text("hello"))` or `Bytes(list)` | `files.put!("k", "hello")` | "This string literal is being used where a non-string type is needed ... Body" |
| S7 | `Cbor.Bytes` is an alias of the package type, so `Cbor.Bytes.([1, 2])` is refused: use `Cbor.bytes([1, 2])` | Making a bytes field by hand | "You are using the type Bytes like a nominal type, but it is an alias" |
| S8 | A typed binding has one type for all its values (MC6): with no annotation, its first use fixes the type, and a second use with another type fails at the second `get!` | One `Kv.json` binding read as two types | "This ? unwraps to ... { theme: Str } But this position needs: List(U64)" |

Runtime facts (from MODULES.md 5 and 6, not compiled; the compiler accepts the wrong form):

| # | Fact |
| --- | --- |
| R1 | A D1 BLOB column reads into `List(U8)`. A `Cbor.Bytes` field type-checks (probe `st_n8.roc`) and each read is `BadData` (edge E34) |
| R2 | D1 rounds an INTEGER of 2^53 or more with no error. Read it with `CAST(x AS TEXT)` into an integer field |
| R3 | `all_tuples!` into a record type type-checks and gives `BadData("row 0: ...")` |
| R4 | R2 refuses a stream with no known length (`Body.writer!`, `compress!`): give `length_bytes` |
| R5 | The `Meta` of `R2.Upload.complete!` has no `http` and no `custom` on the edge; Miniflare has them. Use `head!` |
| R6 | KV refuses `ttl_ms` under 60 s (`KvErr`); `cache_ttl_ms` is 30 s or more |
| R7 | `Cache.put!` with a stream body reads the stream: put a buffered body or a `tee!` copy. Locally a response with no `cache-control` is not stored |
| R8 | `batch.queue` is the queue name, not the binding name |
| R9 | `Queue.json` cannot send an integer above 2^53 (`JSON.stringify` throws); use `Queue.v8` |

Doc drift seen: MODULES.md 5.2 says a bare `?` on `key.metadata` does not compile; `st_n14.roc` shows it does on nightly 2026-10-12.
