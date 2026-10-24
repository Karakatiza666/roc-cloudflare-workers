app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Queue
import pf.Http

Job : { url : Str, tries : U32 }

jobs : Queue(Job)
jobs = Queue.json("JOBS")

fetch! : Request => Try(Response, _)
fetch! = |req| {
	job : Job
	job = req.json!()?
	jobs.send_with!(job, { delay_ms: 1500 })?
	jobs.send_batch!([job, { ..job, tries: 1 }])?
	Ok(Response.from_status(202))
}

queue! : Queue.Batch => Try({}, _)
queue! = |batch| {
	counts = jobs.each!(batch, |msg, job| {
		res = Http.get!(job.url)?
		if res.status >= 500 {
			msg.retry_with!({ delay_ms: 30_000 })
			Ok({})
		} else {
			Ok({})
		}
	})
	if counts.retried > 10 {
		batch.retry_all_with!({ delay_ms: 60_000 })
	}
	Ok({})
}

worker = Worker.{ fetch!, queue! }

event! = |e| worker.event!(e)
