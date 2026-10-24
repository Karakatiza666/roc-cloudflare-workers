app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Cache
import pf.Ctx
import pf.Http
import pf.Queue

Job : { id : U64 }
jobs : Queue(Job)
jobs = Queue.json("JOBS")
fetch! : Request => Try(Response, _)
fetch! = |_req| {
	jobs.send!({ id: 1 })?
	Ok(Response.from_status(202))
}
queue! = |batch| {
	for msg in batch.messages {
		msg.ack!()
	}
	Ok({})
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
