
1. UX issue: the shared error type e of Worker(e) (and of Object.class, Rpc.entrypoint)

All handlers in Worker.{ fetch!, scheduled!, ... } share one error type e. When one handler's error type is closed, every other handler must also be closed. This happens when a handler is annotated Try(Response, []), or when it gives as is the result of a helper that handles all its errors (Roc infers Try(Response, []) for a function with no Err). Then a handler that has errors (for example db.run!(...)? in scheduled!) fails with "invalid nominal record" at worker = Worker.{ ... }. The error prints two full nine-field records and does not point at the handler that caused it.

Repro (nightly-2026-10-12, platform 703a519): cloudflare-workers/research/plugin-probes/p9_join.roc and p12_closed_a.roc.

The shared e does nothing for the app: Worker.event! only turns an Err into Failed(Str.inspect(e)) (MODULES.md 3). The same is true for Object.class and Rpc.entrypoint, which turn errors into log text. Please let each handler keep its own error type, so that one closed handler cannot break the others. For example, erase the error to Str per field when the record is built, or use per-field constructors. Keep the app-side form Worker.{ fetch!, scheduled! } if you can, and keep Err → Failed → 500 and the log line the same.

When it is fixed, these must check: p9_join.roc (a fetch! annotated [] next to a scheduled! with D1 errors) and p12_closed_a.roc. Also update MODULES.md 3 ("e is one error type for all handlers") and the "one error type" row in MODULES.md 7.


2. Some mistakes type-check and then fail every time at runtime. This is the largest class. The compiler cannot help, so each one costs a deploy and a debug cycle.

  ┌──────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────┐
  │                  Issue                   │                                            What happens                                            │                                        Possible fix                                        │
  ├──────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ D1 BLOB read into a Cbor.Bytes field     │ Type-checks, then every read is BadData                                                            │ Make Cbor.Bytes also read the array form, or remove the difference between it and List(U8) │
  ├──────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ D1 INTEGER of 2^53 or more               │ Silently rounded. A typed read gives BadData, and the fix is CAST(x AS TEXT) in each query         │ Do the cast in the platform for integer fields, or have a typed read that does it          │
  ├──────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ set_alarm!(60_000)                       │ Takes an absolute time, so a delay fires the alarm at once. The name and the U64 look like a delay │ set_alarm_at! plus set_alarm_in!, or a tagged argument At(ms) / In(ms)                     │
  ├──────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ R2 put! of a stream with no known length │ Refused at runtime (after Body.writer! or compress!)                                               │ Make the stream types carry their length, or require length_bytes in a separate function   │
  ├──────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ KV ttl_ms under 60 s                     │ KvErr at runtime                                                                                   │ Clamp it, or document it in the signature                                                  │
  ├──────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Cache.put! with a stream body            │ Uses up the stream, so the response body that follows is empty                                     │ Make the tee! part of the function                                                         │
  ├──────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Body read after Ctx.respond!             │ BodyErr. The handler's return value after respond! is also silently ignored                        │ A shape that takes the remaining work as an argument, so the order is in the types         │
  └──────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────┘

3. Untyped arguments hide type errors until a later read. socket.attach! takes any a, and attachment! reads any a. Neither ties the stored type to the read type. With the Roc trap that { name } is a block and not a record, you store a Str and
every later read is BadData. Object.Cell(a) and Queue(a) already solve this: you declare the type once and the same constant writes and reads. Attachments, and Memo across deploys, could follow the same pattern.

4. The platform calls zero-argument functions in two ways. Time.now_ms!, WebCrypto.random_uuid!, Body.writer! and Ctx.pass_through! take {}. The platform's own example writes helpers with () (d1! : () => Response, called as d1!()). Every
author meets "too few args" at least once. Choose one form. () matches the language docs.

5. Most of a project lives outside Roc, and nothing creates it. A Worker needs four files. A Durable Object class name appears in three places: Object.class("Room"), export const Room = objectClass("Room") (before makeHandler), and
new_sqlite_classes in wrangler.toml. The load-time check finds a mismatch, but only at deploy. The shim must come from the same release as the platform, and it is not on the npm registry. A template, or a command that writes worker.js and the
wrangler bindings from the manifest, would remove a whole class of errors.

6. --no-cache is required for every build. A warm build cache gave other code in the same build. Every user must know this flag, and a user who forgets it may get a wrong binary with no error. This is probably a compiler bug, not the
platform's, but the platform passes it on to each user. A minimal repro filed upstream would be worth more than the README line.

7. Several errors point far from their cause.
- An unannotated req.json!() result fails at worker = Worker.{ fetch! }.
- req.method on an unannotated fetch! turns req into a plain record. req.segments() works there because method calls wait for the type and field reads do not. A req.method() accessor, used in the docs, would avoid this. Response.status has
  the same issue.

8. The format of typed data depends on the binding, and the names do not say which. Kv.json stores JSON. Queues use Queue.json, but it cannot send integers above 2^53 (you must use Queue.v8). Cells, Memo, RPC and attachments use CBOR.
List(U8) reaches JS as an array of numbers, and Cbor.Bytes reaches it as a Uint8Array. An author must learn this table to know what JS sees and what survives a round trip.

9. Low-level modules sit beside the app modules. Js, Io (its program builders), Native and Cbor are in the 37 exposed modules at the same level as D1 and Http. A model or a new user who browses the index sees the program ops (Root, Slot,
Call) next to the real API. You could move the escape hatch under one module, for example Js. You would keep Io.both! / Io.race! / Io.all! public, because apps use them.

10. Some edge facts have no helper. Http.send! gives Ok for a DNS failure (530, error code: 1016) and for a blocked address (403, 1003). An app that must tell these from a real origin answer has to match the status and the body text itself. A
small Http.cloudflare_error(res) helper would cover it.