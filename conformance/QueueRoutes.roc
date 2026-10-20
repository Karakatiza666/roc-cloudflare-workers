## `Queue` (MODULES.md 6, PLAN.md 8f). The producer routes send with the constants below. `consume!` is the `queue!` of the
## app: it reads each batch by the name of its queue and writes one log line for each message (`Log.info!`), which
## `checks/queue.mjs` reads from the log of workerd. `?label=` makes the lines unique. The bindings and the queue names are in
## `checks/queue.mjs`: JOBS is `jobs`, TEXTS is `texts`, BIN is `bin`, V8Q is `v8` (its consumer is JS, in `worker.js`).
import pf.Request
import pf.Response
import pf.Queue
import pf.Io
import pf.Log
import pf.Cbor
import Q

Job : { n : U64, label : Str }

jobs : Queue(Job)
jobs = Queue.json("JOBS")

texts : Queue(Str)
texts = Queue.text("TEXTS")

bin : Queue(List(U8))
bin = Queue.bytes("BIN")

V8Msg : { n : U64, big : U64, data : Cbor.Bytes }

v8q : Queue(V8Msg)
v8q = Queue.v8("V8Q")

QueueRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		job = { n: Q.num(req, "n"), label: Q.text(req, "label") }
		delay = Q.num(req, "delay")
		count = Q.num(req, "count")
		many = Iter.fold(U64.until(0, count), [], |acc, i| acc.append({ n: i, label: job.label }))
		match path {
			["send"] => out(jobs.send!(job))
			["send_io"] => out(Io.run!(jobs.send(job)))
			["send_with"] => out(jobs.send_with!(job, { delay_ms: delay }))
			["send_with_io"] => out(Io.run!(jobs.send_with(job, { delay_ms: delay })))
			["batch"] => out(jobs.send_batch!(many))
			["batch_io"] => out(Io.run!(jobs.send_batch(many)))
			["batch_with"] => out(jobs.send_batch_with!(many, { delay_ms: delay }))
			["batch_with_io"] => out(Io.run!(jobs.send_batch_with(many, { delay_ms: delay })))
			["text"] => out(texts.send!(Q.text(req, "s")))
			["bytes"] => out(bin.send!([1, 2, 255]))
			["v8"] => out(v8q.send!({ n: 5, big: 1_152_921_504_606_846_976, data: Cbor.bytes([1, 2, 3]) }))
			_ => Response.from_text(404, "no route")
		}
	}

	## The `queue!` of the app.
	consume! : Queue.Batch => Try({}, [Boom])
	consume! = |batch| match batch.queue() {
		"jobs" => {
			r = jobs.each!(batch, handle_job!)
			Log.info!("jobs batch", { acked: r.acked, retried: r.retried })
			Ok({})
		}
		"texts" => {
			r = texts.each!(batch, |msg, s| Ok(Log.info!("text", { s, attempts: msg.attempts() })))
			Log.info!("texts batch", { acked: r.acked, retried: r.retried })
			Ok({})
		}
		"bin" => {
			_ = bin.each!(batch, |_msg, b| Ok(Log.info!("bytes", { len: b.len(), last: b.last().ok_or(0) })))
			Ok({})
		}
		# The low level: the functions of the batch and of the message.
		"ack-second" => {
			match batch.messages() {
				[_, second, ..] => second.ack!()
				_ => {}
			}
			Ok({})
		}
		"retry-second-with" => {
			match batch.messages() {
				[_, second, ..] => second.retry_with!({ delay_ms: 2_500 })
				_ => {}
			}
			Ok({})
		}
		"retry-all" => {
			batch.retry_all!()
			Ok({})
		}
		"retry-all-with" => {
			batch.retry_all_with!({ delay_ms: 1_500 })
			Ok({})
		}
		"ack-all" => {
			batch.ack_all!()
			Ok({})
		}
		"handler-err" => Err(Boom)
		_ => Ok({})
	}
}

## A job that logs its fields. A label that starts with `fail-once` fails at the first attempt.
handle_job! : Queue.Message, Job => Try({}, [Failing(Str)])
handle_job! = |msg, job| {
	Log.info!("job", { n: job.n, label: job.label, attempts: msg.attempts() })
	if (job.label.starts_with("fail-once") and msg.attempts() == 1) Err(Failing(job.label)) else Ok({})
}

out : Try({}, e) -> Response
out = |r| Response.from_text(
	200,
	match r {
		Ok(_) => "Ok"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)
