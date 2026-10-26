app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Http
import pf.Memo

Config : { motd : Str }

load_config! = || {
	res = Http.get!("https://example.com/config.json")?
	res.json!()
}

config = Memo.new("config", { max_age_ms: 60_000, load!: load_config! })

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	cfg = config.get!()?
	Ok(Response.from_text(200, cfg.motd))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
