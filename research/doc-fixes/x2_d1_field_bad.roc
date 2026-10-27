app [event!] { pf: platform "../../platform/main.roc" }

## X2 probe: an unannotated row whose field is used only with a method (`row.n.to_str()`).
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	row = db.first!("select count(*) as n from users", Sql.none)?
	Ok(Response.from_text(200, row.n.to_str()))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
