app [event!] { pf: platform "../../bench/platform/main.roc" }

## Probe: no cbor entry. A generic helper with NO annotation: the compiler infers the `where` clause.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1

db = D1.binding("DB")

Person : { id : I64, name : Str }

read! = |sql| db.all!(sql, [])

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows : Try(List(Person), _)
	rows = read!("SELECT id, name FROM t")
	Ok(Response.from_text(200, Str.inspect(rows)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
