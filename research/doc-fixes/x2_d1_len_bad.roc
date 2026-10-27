app [event!] { pf: platform "../../platform/main.roc" }

## X2 probe: unannotated D1 rows, used only with `.len()`.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	rows = db.all!("select name from users", Sql.none)?
	Ok(Response.from_text(200, rows.len().to_str()))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
