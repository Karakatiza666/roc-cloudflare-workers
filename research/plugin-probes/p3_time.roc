app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Time
import pf.Log

fetch! = |_req| {
	now = Time.now_ms!()
	Log.info!("tick", { now })
	Ok(Response.from_text(200, now.to_str()))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
