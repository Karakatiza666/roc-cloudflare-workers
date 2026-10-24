app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Kv

db = D1.binding("DB")

Prefs : { theme : Str }

prefs : Kv(Prefs)
prefs = Kv.json("PREFS")

Row : { n : I64 }

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	row : Row
	row = db.first!("select 1 as n", [])?
	p = prefs.get!("me")?
	Ok(Response.from_text(200, "${row.n.to_str()} ${p.theme}"))
}

scheduled! : Worker.Scheduled => Try({}, _)
scheduled! = |_s| {
	_ = db.run!("delete from t", [])?
	Ok({})
}

worker = Worker.{ fetch!, scheduled! }

event! = |e| worker.event!(e)
