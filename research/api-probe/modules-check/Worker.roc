import Request
import Response
import Queue
import Rpc
import Object

## The handlers of a Worker, all optional. Each one has its own result type.
## `e` is one error type for all: the tag unions of the handlers join.
Worker(e) := {
	fetch! ?: Request => Try(Response, e),
	scheduled! ?: { cron : Str, time_ms : U64 } => Try({}, e),
	queue! ?: Queue.Batch => Try({}, e),
	rpc ?: List(Rpc.Handler({})),
	objects ?: List(Object.Class),
}.{
	Event : [
		Fetch(Request),
		Scheduled({ cron : Str, time_ms : U64 }),
		Queue(Queue.Batch),
		Rpc(Str, List(U8)),
		Object(Str, Str, Object.Event),
	]

	Outcome : Object.Outcome

	event! : Worker(e), Worker.Event => Worker.Outcome
	event! = |w, ev| match ev {
		Fetch(req) => match w.?fetch! {
			Ok(f!) => match f!(req) {
				Ok(res) => Respond(res)
				Err(e) => Failed(Str.inspect(e))
			}
			Err(MissingField) => Unhandled
		}
		Scheduled(job) => match w.?scheduled! {
			Ok(f!) => done(f!(job))
			Err(MissingField) => Unhandled
		}
		Queue(batch) => match w.?queue! {
			Ok(f!) => done(f!(batch))
			Err(MissingField) => Unhandled
		}
		Rpc(method, arg) => match Rpc.serve!(w.?rpc ?? [], {}, method, arg) {
			Ok(bytes) => Reply(bytes)
			Err(msg) => Failed(msg)
		}
		Object(class, id, oev) => match (w.?objects ?? []).find_first(|c| c.name == class) {
			Ok(c) => {
				run! = c.run!
				run!(Object.Self.{ class, id }, oev)
			}
			Err(_) => Unhandled
		}
	}
}

done : Try({}, e) -> Object.Outcome
done = |r| match r {
	Ok({}) => Done
	Err(e) => Failed(Str.inspect(e))
}
