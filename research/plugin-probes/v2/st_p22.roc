app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	users = db.all!("select id, name from users", Sql.none)?
	Ok(Response.from_json(200, users))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
