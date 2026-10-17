app [event!] { pf: platform "../../bench/platform/main.roc" }

## Probe: no cbor entry. A helper with a `where` clause that names `Cbor.Parseable`.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Io

db = D1.binding("DB")

Person : { id : I64, name : Str }

read! : Str => Try(rows, [D1Err(Io.Thrown), BadData(Str), TooLarge, ..]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
read! = |sql| db.all!(sql, [])

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows : Try(List(Person), _)
	rows = read!("SELECT id, name FROM t")
	Ok(Response.from_text(200, Str.inspect(rows)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
