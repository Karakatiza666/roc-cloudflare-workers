app [event!] { pf: platform "../../platform/main.roc" }

## X2 probe, the fix: annotate the binding of each D1 read.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |req| {
	if req.segments() == ["n"] {
		row : { n : I64 }
		row = db.first!("select count(*) as n from users", Sql.none)?
		Ok(Response.from_text(200, row.n.to_str()))
	} else {
		rows : List({ name : Str })
		rows = db.all!("select name from users", Sql.none)?
		Ok(Response.from_json(200, rows))
	}
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
