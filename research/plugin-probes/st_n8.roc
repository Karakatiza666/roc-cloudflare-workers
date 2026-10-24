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

Avatar : { id : I64, avatar : Cbor.Bytes }
fetch! : Request => Try(Response, _)
fetch! = |_req| {
	a : Avatar
	a = db.first!("select id, avatar from users", [])?
	Ok(Response.from_bytes(200, "image/png", a.avatar.to_list()))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
