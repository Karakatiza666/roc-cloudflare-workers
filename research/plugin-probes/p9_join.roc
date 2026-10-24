app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1

db = D1.binding("DB")

fetch! : Request => Try(Response, [])
fetch! = |_req| Ok(Response.from_text(200, "hi"))

scheduled! = |_s| {
	_ = db.run!("delete from t", [])?
	Ok({})
}

worker = Worker.{ fetch!, scheduled! }

event! = |e| worker.event!(e)
