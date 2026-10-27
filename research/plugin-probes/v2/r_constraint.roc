app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1/GcDNxAwPR5tSzqU8T2Kdj35CK3sQMRQDB8ywwfZKdrm.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

User : { id : I64, name : Str }

# bare param; old pattern Infra(Constraint) ; new pattern
a! : Str => Try(Response, _)
a! = |name| {
	u : User
	u = db.first!("SELECT id, name FROM users WHERE name = ?", name)?
	_ = db.run!("DELETE FROM users WHERE name = ?", name)?
	Ok(Response.from_json(200, { id: u.id }))
}

old! : Str => Try(Response, _)
old! = |name| match a!(name) {
	Ok(r) => Ok(r)
	Err(Infra(Constraint(_))) => Ok(Response.from_status(409))
	Err(e) => Err(e)
}

new! : Str => Try(Response, _)
new! = |name| match a!(name) {
	Ok(r) => Ok(r)
	Err(Constraint(_)) => Ok(Response.from_status(409))
	Err(e) => Err(e)
}

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["o", n] => old!(n)
	["n", n] => new!(n)
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({ fetch!: fetch!, bindings: [db.declare()] })
event! = |e| worker.event!(e)
