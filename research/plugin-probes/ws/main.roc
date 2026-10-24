app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1

db = D1.binding("DB")

# A: first! with no annotation, field use
fetch! = |req| match req.segments() {
	["pkg", name] => {
		pkg = db.first!("select name, version from pkg where name = ?", [Text(name)])?
		Ok(Response.from_text(200, pkg.version))
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
