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
	_ = files.put!("k", Text("hello"))?
	obj = files.get!("k")?
	s = obj.body.text!()?
	Ok(Response.from_text(200, s))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
