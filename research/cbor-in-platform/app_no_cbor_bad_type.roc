app [event!] { pf: platform "../../bench/platform/main.roc" }

## Probe (negative control): no cbor entry. A row type that has no CBOR parser (a function field). It must NOT compile,
## so the probes `app_no_cbor_*` do check the derived parser, not only the syntax.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1

db = D1.binding("DB")

Bad : { id : I64, f : I64 -> I64 }

read! : Str => Try(List(Bad), _)
read! = |sql| db.all!(sql, [])

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows = read!("SELECT id FROM t")
	Ok(Response.from_text(200, if rows.is_ok() "ok" else "err"))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
