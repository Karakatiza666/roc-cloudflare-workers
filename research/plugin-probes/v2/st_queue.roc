app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Queue
import pf.Http

Job : { url : Str }

jobs : Queue(Job)
jobs = Queue.json("JOBS")

Mail : { to : Str, subject : Str }

mails : Queue(Mail)
mails = Queue.json("MAILS")

fetch! : Request => Try(Response, _)
fetch! = |req| {
	job : Job
	job = req.json!()?
	jobs.send_with!(job, { delay_ms: 2_000 })?
	mails.send_batch!([{ to: "a@example.com", subject: "queued" }, { to: "b@example.com", subject: "queued" }])?
	Ok(Response.from_status(202))
}

crawl! : Queue.Batch => Try({}, _)
crawl! = |batch| {
	health = Http.get!("https://example.com/health")?
	if health.status() != 200 {
		batch.retry_all_with!({ delay_ms: 300_000 })
	} else {
		_counts = jobs.each!(
			batch,
			|msg, job| {
				res = Http.get!(job.url)?
				if res.status() >= 500 and msg.attempts() < 5 {
					Err(Upstream(res.status()))
				} else {
					Ok({})
				}
			},
		)
	}
	Ok({})
}

drain_mails! : Queue.Batch => Try({}, _)
drain_mails! = |batch| {
	for msg in batch.messages() {
		if msg.attempts() > 3 {
			msg.ack!()
		} else {
			msg.retry_with!({ delay_ms: 60_000 })
		}
	}
	Ok({})
}

queue! : Queue.Batch => Try({}, _)
queue! = |batch| match batch.queue() {
	"crawl-jobs" => crawl!(batch)
	"mails" => drain_mails!(batch)
	other => Err(UnknownQueue(other))
}

worker = Worker.new({ fetch!: fetch!, queue!: queue!, bindings: [jobs.declare(), mails.declare()] })

event! = |e| worker.event!(e)
