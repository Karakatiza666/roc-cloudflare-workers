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

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(404))

purge! : Worker.Scheduled => Try({}, _)
purge! = |s| {
	Log.info!("cron", { cron: s.cron(), time_ms: s.time_ms() })
	_ = db.run!("DELETE FROM items WHERE expires_ms < ?", (s.time_ms().to_i64_wrap(),))?
	Ok({})
}

worker = Worker.new({ fetch!: fetch!, scheduled!: purge!, crons: [Worker.cron("*/5 * * * *", purge!)], bindings: [db.declare()] })

event! = |e| worker.event!(e)
