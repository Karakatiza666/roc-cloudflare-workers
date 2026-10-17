app [event!] { pf: platform "plat_named/main.roc" }

## Probe: the platform module `Cbor` (plat_named/Cbor.roc) wraps the package as `CborPkg`. No cbor entry in the app.
## D1.all! into a record, a `where` clause with `Cbor.Parseable`, a field of type `Cbor.Bytes`, `Cbor.parse` and `Cbor.encode`.

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Io
import pf.Sql
import pf.Cbor

db = D1.binding("DB")

Person : { id : I64, name : Str, avatar : Cbor.Bytes }

read! : Str => Try(rows, [D1Err(Io.Thrown), BadData(Str), TooLarge, Constraint(Sql.Constraint)]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
read! = |sql| db.all!(sql, [])

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows : Try(List(Person), _)
	rows = read!("SELECT id, name, avatar FROM t")
	raw = Cbor.encode({ id: 7.I64, name: "x", avatar: Cbor.bytes([1, 2, 3]) })
	back : Try(Person, _)
	back = Cbor.parse(raw)
	Ok(Response.from_text(200, "${Str.inspect(rows)} ${Str.inspect(back)}"))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
