app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.2/5xpAVbae476YyEYkJSpkTAZFPeG43H5R7KM8u9j3rYKX.tar.zst" }
import pf.Worker
import pf.Request
import pf.Response
import pf.Memo
import pf.Kv
import pf.D1
import pf.Sql
import pf.Io

db = D1.binding("DB")
prefs = Kv.json("PREFS")
cell : Kv.Cell(Str)
cell = prefs.cell("motd")

create_tables! : () => Try({}, [Constraint(Sql.Constraint), Infra([D1Err(Io.Thrown)])])
create_tables! = || {
	_ = db.run!("CREATE TABLE IF NOT EXISTS t (id INTEGER)", Sql.none)?
	Ok({})
}

tables : () -> Memo({}, _)
tables = || Memo.new("tables", { max_age_ms: 3_600_000, load!: create_tables! })

motd : () -> Memo(Str, _)
motd = || Memo.new("motd", { max_age_ms: 60_000, load!: || cell.get_or!("none") })

# The Memo errors join with the errors of the other calls by `?`.
Faults : [D1Err(Io.Thrown), KvErr(Io.Thrown), BadData(Str), TooLarge]

work! : () => Try(Str, [Constraint(Sql.Constraint), Infra(Faults)])
work! = || {
	tables().get!()?
	m = motd().get!()?
	n : List({ n : I64 })
	n = db.all!("SELECT 1 AS n", Sql.none)?
	Ok("${m} ${n.len().to_str()}")
}

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, work!()?))

worker = Worker.new({ fetch!: fetch!, bindings: [db.declare(), cell.declare()] })
event! = |e| worker.event!(e)
