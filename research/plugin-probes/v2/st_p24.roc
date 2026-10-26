app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Id64

db = D1.binding("DB")

Ev : { id : Id64, kind : Str }

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	ev : Ev
	ev = db.first!("select cast(id as text) as id, kind from events", Sql.none)?
	Ok(Response.from_json(200, ev))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
