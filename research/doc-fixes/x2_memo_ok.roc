app [event!] { pf: platform "../../platform/main.roc" }

## X2 probe, the fix: annotate the loader of the `Memo`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Http
import pf.Memo

Config : { name : Str }

config : Memo(Config)
config = Memo.new("config", { max_age_ms: 60_000 })

load! : () => Try(Config, _)
load! = || {
	res = Http.send!(Request.get("https://example.com/config"))?
	res.json!()
}

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	c = config.get!(load!)?
	Ok(Response.from_text(200, c.name))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
