import Io
import Request
import Response
import Queue
import Rpc
import Object

## The handlers of a Worker, all optional. Each one has its own result type.
## `e` is one error type for all: the tag unions of the handlers join.
Worker(e) := {
	fetch! ?: Request => Try(Response, e),
	scheduled! ?: Worker.Scheduled => Try({}, e),
	queue! ?: Queue.Batch => Try({}, e),
	tail! ?: List(Worker.TraceItem) => Try({}, e),
	rpc ?: List(Rpc.Handler({})),
	objects ?: List(Object.Class),
}.{
	## The payload of a cron run (MODULES.md 3).
	Scheduled := { cron : Str, time_ms : U64 }.{
		## `controller.noRetry()`, one `call!`.
		no_retry! : Worker.Scheduled => {}
		no_retry! = |s| {
			_ = Io.run!(Io.new(["scheduled.no_retry", s.cron], |r| r))
			{}
		}
	}

	## One item of the batch of a Tail Worker: plain data, read as CBOR (MC5).
	## `parser_for : _`: a nominal type must opt in to the derived parser.
	TraceItem := {
		script_name : Try(Str, [Missing]),
		outcome : Str,
		event_timestamp_ms : Try(U64, [Missing]),
		event : Try({ request : { method : Str, url : Str, headers : List((Str, Str)), cf : Try(Request.Cf, [Missing]) }, response : Try({ status : U16 }, [Missing]) }, [Missing]),
		logs : List({ timestamp_ms : U64, level : Str, message : Str }),
		exceptions : List({ timestamp_ms : U64, name : Str, message : Str }),
	}.{
		parser_for : _
	}

	## API.md 10.1, without the kinds that the prototype does not have (`Email`, `EntrypointFetch`, `Other`, `Manifest`).
	Event : [
		Fetch(Request),
		Scheduled(Worker.Scheduled),
		Queue(Queue.Batch),
		Tail(List(Worker.TraceItem)),
		Rpc(Str, List(U8)),
		Object({ class : Str, id : Str, event : Object.Event }),
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
		Tail(items) => match w.?tail! {
			Ok(f!) => done(f!(items))
			Err(MissingField) => Unhandled
		}
		Rpc(method, arg) => match Rpc.serve!(w.?rpc ?? [], {}, method, arg) {
			Ok(bytes) => Reply(Packed(bytes))
			Err(msg) => Failed(msg)
		}
		Object({ class, id, event }) => match (w.?objects ?? []).find_first(|c| c.name == class) {
			Ok(c) => {
				run! = c.run!
				run!(Object.Self.{ class, id }, event)
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
