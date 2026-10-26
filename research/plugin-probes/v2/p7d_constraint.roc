app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Env
import pf.Log
import pf.Sql

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	res = db.run!("INSERT INTO t VALUES (1)", Sql.none)
	match res {
		Ok(_) => Ok(Response.from_status(201))
		Err(Infra(Constraint({ kind: Unique, .. }))) => Ok(Response.from_status(409))
		Err(e) => Err(e)
	}
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
