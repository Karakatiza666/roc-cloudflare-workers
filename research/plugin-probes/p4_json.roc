app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response

fetch! = |req| {
	body = req.json!()?
	Ok(Response.from_json(200, { echo: body.name }))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
