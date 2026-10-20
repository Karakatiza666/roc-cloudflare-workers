app [event!] { pf: platform "../../../platform/main.roc" }

## N5 G1a, open point 1 (API.md 6): `Io.both!` of a D1 call and an Http call gives one merged `Infra([...])`.
## `roc check` only. The annotation of `joined` is the type that API.md says.
import pf.Worker
import pf.Io
import pf.D1
import pf.Http
import pf.Response
import pf.Sql

db : D1
db = D1.binding("DB")

joined! : Str => Try((Sql.Rows, Response), [Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint), HttpErr(Io.Thrown), Network(Io.Thrown), TooLarge])])
joined! = |url| Io.both!(db.rows("SELECT 1", Sql.none), Http.get(url))

fetch! = |_req| match joined!("https://example.com/jwks") {
	Ok(_) => Ok(Response.from_text(200, "ok"))
	Err(Infra(D1Err(_))) | Err(Infra(Constraint(_))) => Ok(Response.from_text(500, "db"))
	Err(Infra(HttpErr(_))) | Err(Infra(Network(_))) => Ok(Response.from_text(502, "http"))
	Err(Infra(TooLarge)) => Ok(Response.from_text(502, "large"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
