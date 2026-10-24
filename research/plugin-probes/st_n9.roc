app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Kv
import pf.R2
import pf.Cbor
import pf.Queue

db = D1.binding("DB")
files = R2.binding("FILES")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	page = files.list!({})?
	more = match page.next {
		More(c) => c
		Done => ""
	}
	Ok(Response.from_json(200, { keys: page.objects.map(|o| o.key), more }))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
