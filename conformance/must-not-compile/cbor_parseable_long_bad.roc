app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile (roc-cbor 0.2.0, MODULES.md 5.1): a wrapper around `D1.all!` with the old long `Parseable` form. D1 now needs `Readable(errs)`, whose error row also has `MissingRequiredField(Str)`.
## `conformance/must-not-compile.sh` runs `roc check` on it. Its pair is `cbor_readable_ok.roc`.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Io
import pf.Cbor

db = D1.binding("DB")

all_rows! : Str => Try(rows, [Constraint(Sql.Constraint), Infra([D1Err(Io.Thrown), BadData(Str), TooLarge])]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
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
