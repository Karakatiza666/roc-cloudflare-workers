app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1/GcDNxAwPR5tSzqU8T2Kdj35CK3sQMRQDB8ywwfZKdrm.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Io

db = D1.binding("DB")

old! : Str => Try(Response, [Constraint(Sql.Constraint), Infra([D1Err(Io.Thrown)])])
old! = |name| match db.run!("DELETE FROM users WHERE name = ?", name) {
	Ok(_) => Ok(Response.from_status(200))
	Err(Infra(Constraint(_))) => Ok(Response.from_status(409))
	Err(e) => Err(e)
}

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["o", n] => Ok(old!(n)?)
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({ fetch!: fetch!, bindings: [db.declare()] })
event! = |e| worker.event!(e)
