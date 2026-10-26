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
fetch! = |_req| {
	raced = Io.race!([Http.get("https://slow.example.com").map(Got), Time.sleep(5_000).map(|_| TimedOut)])
	match raced.result {
		Ok(Got(res)) => Ok(Response.from_text(200, res.status().to_str()))
		_ => Ok(Response.from_status(504))
	}
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
