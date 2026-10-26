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

fetch! : Request => Try(Response, _)
fetch! = |req| {
	text = req.text!()?
	Ok(Response.from_text(202, "queued").after(|| {
		Log.info!("work", { size: text.count_utf8_bytes() })
		Ok({})
	}))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
