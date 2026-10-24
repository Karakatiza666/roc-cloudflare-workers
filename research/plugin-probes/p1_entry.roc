app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response

# No annotations at all
fetch! = |req| match req.segments() {
	[] => Ok(Response.from_text(200, "hi"))
	_ => Ok(Response.from_status(404))
}

scheduled! = |s| {
	s.no_retry!()
	Ok({})
}

worker = Worker.{ fetch!, scheduled! }

event! = |e| worker.event!(e)
