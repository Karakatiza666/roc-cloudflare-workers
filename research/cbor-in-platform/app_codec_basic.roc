app [event!] { pf: platform "plat/main.roc" }

## Probe: the platform wraps Cbor in `pf.Codec`. No cbor entry in the app. D1.all! into a record, a `where` clause
## with `Codec.Parseable`, a field of type `Codec.Bytes`, `Codec.parse` and `Codec.encode`.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Io
import pf.Sql
import pf.Codec

db = D1.binding("DB")

Person : { id : I64, name : Str, avatar : Codec.Bytes }

read! : Str => Try(rows, [D1Err(Io.Thrown), BadData(Str), TooLarge, Constraint(Sql.Constraint)]) where [rows.Codec.Parseable([InvalidCbor(U64), ..errs])]
read! = |sql| db.all!(sql, [])

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows : Try(List(Person), _)
	rows = read!("SELECT id, name, avatar FROM t")
	raw = Codec.encode({ id: 7.I64, name: "x", avatar: Codec.bytes([1, 2, 3]) })
	back : Try(Person, _)
	back = Codec.parse(raw)
	Ok(Response.from_text(200, "${Str.inspect(rows)} ${Str.inspect(back)}"))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
