app [event!] { pf: platform "../../bench/platform/main.roc" }

## Probe: no cbor entry. D1.all! into a record type, the type comes from an annotation, no `where` clause.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1

db = D1.binding("DB")

Person : { id : I64, name : Str }

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows : Try(List(Person), _)
	rows = db.all!("SELECT id, name FROM t", [])
	Ok(Response.from_text(200, Str.inspect(rows)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
