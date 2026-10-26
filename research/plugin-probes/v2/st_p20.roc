app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	info = db.run!("INSERT INTO users (name) VALUES (?)", "ann")?
	_ = db.run!("DELETE FROM users", [])?
	Ok(Response.from_text(200, info.changes.to_str()))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
