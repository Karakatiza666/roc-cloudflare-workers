app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.WebCrypto
import pf.Env
import pf.Body

fetch! : Request => Try(Response, _)
fetch! = |req| {
	id = WebCrypto.random_uuid!()
	bytes = WebCrypto.random!(16)
	v = Env.var!("NAME")?
	{ body, writer } = Body.writer!()?
	writer.close!()
	Ok(Response.from_text(200, "${id} ${v} ${bytes.len().to_str()}"))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
