app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Time
import pf.Log
import pf.D1
import pf.Http
import pf.Io
import pf.Ctx
import pf.Body
import pf.Env
import pf.WebCrypto
import pf.Memo
import pf.Sql

Count : { n : I64 }
db = D1.binding("DB")

count! : () => Try(Response, _)
count! = || {
	got : Try(Count, _)
	got = db.first!("SELECT count(*) AS n FROM items", Sql.none)
	match got {
		Ok({ n }) => Ok(Response.from_text(200, n.to_str()))
		Err(NotFound) => Ok(Response.from_status(404))
		Err(e) => {
			Log.error!("count", { error: Str.inspect(e) })
			Ok(Response.from_status(503))
		}
	}
}

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["count"] => Ok(count!()?)
	_ => {
		text = req.text!()?
		Ok(Response.from_text(200, text))
	}
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
