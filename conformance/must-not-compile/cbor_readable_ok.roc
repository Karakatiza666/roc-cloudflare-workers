app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control: the same wrapper with `Cbor.Readable(errs)` compiles.
## `conformance/must-not-compile.sh` runs `roc check` on it. Its pair is `cbor_parseable_long_bad.roc`.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Io
import pf.Cbor

db = D1.binding("DB")

all_rows! : Str => Try(rows, [Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge])]) where [rows.Cbor.Readable(errs)]
all_rows! = |sql| db.all!(sql, Sql.none)

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows : Try(List({ id : I64 }), _)
	rows = all_rows!("SELECT 1 AS id")
	_ = rows
	Ok(Response.from_status(204))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
