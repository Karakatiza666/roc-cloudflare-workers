## The entry types (API.md 10.1) and the `Worker` wrapper (MODULES.md 3): a record of handlers, all optional,
## each with the result type of its kind. `e` is one error type for all handlers: their tag unions join.
## `rpc`, `entrypoints` and `objects` (PLAN.md 8f): their handlers erase their types, so each has its own error type.
import Io
import Rpc
import Js
import Request
import Response
import Queue
import Email
import Object
import http.Header

Worker(e) := {
	fetch! ?: Request => Try(Response, e),
	scheduled! ?: Worker.Scheduled => Try({}, e),
	queue! ?: Queue.Batch => Try({}, e),
	email! ?: Email.Mail => Try({}, e),
	tail! ?: List(Worker.TraceItem) => Try({}, e),
	other! ?: Str, Js => Try(Js, e),
	rpc ?: List(Rpc.Handler({})),
	entrypoints ?: List(Rpc.Entrypoint),
	objects ?: List(Object.Class),
}.{

	## One event of Workers (API.md 10.1). Phase A has all tags. The shim sends `Fetch`, `Scheduled`, `Other`, and since
	## PLAN.md 8f `Rpc`, `EntrypointFetch`, `Object` and `Manifest`.
	Event : [
		Fetch(Request),
		Scheduled(Worker.Scheduled),
		Queue(Queue.Batch),
		Email(Email.Mail),
		Rpc({ entrypoint : Str, method : Str, arg : List(U8) }),
		EntrypointFetch({ entrypoint : Str, request : Request }),
		Object({ class : Str, id : Str, event : Object.Event }),
		Tail(List(Worker.TraceItem)),
		Other({ kind : Str, payload : Js }),
		Manifest,
	]

	## What the app gives back for an event (API.md 10.1).
	Outcome : [
		Respond(Response),
		Reply(Js),
		Done,
		Failed(Str),
		Unhandled,
	]

	## The payload of a cron run (MODULES.md 3). `time_ms` is `controller.scheduledTime`, the planned time.
	Scheduled := { cron : Str, time_ms : U64 }.{

		## `controller.noRetry()`, one `call!` with no wait. The shim never calls it by itself (MODULES.md 3).
		## A throw is dropped: only a `Worker.Scheduled` of a `Scheduled` event has a controller.
		no_retry! : Worker.Scheduled => {}
		no_retry! = |_s| {
			_ = Io.call!([Call(Root("event"), "noRetry", [])])
			{}
		}
	}

	## One item of the batch of a Tail Worker (MODULES.md 3): plain data, read as CBOR in phase B (MC5, PLAN.md 8f).
	## `parser_for : _`: a nominal type opts in to the derived parser (MODULES.md 15).
	TraceItem := {
		script_name : Try(Str, [Missing]),
		outcome : Str,
		event_timestamp_ms : Try(U64, [Missing]),
		event : Try({ request : { method : Str, url : Str, headers : List(Header), cf : Try(Request.Cf, [Missing]) }, response : Try({ status : U16 }, [Missing]) }, [Missing]),
		logs : List({ timestamp_ms : U64, level : Str, message : Str }),
		exceptions : List({ timestamp_ms : U64, name : Str, message : Str }),
	}.{
		parser_for : _
	}

	## The one entry, made from the handlers that the app gives (`event! = |e| worker.event!(e)`).
	## A missing handler gives `Unhandled`. An `Err(e)` gives `Failed` with `Str.inspect(e)`.
	event! : Worker(e), Worker.Event => Worker.Outcome
	event! = |w, ev| match ev {
		Fetch(req) => match w.?fetch! {
			Ok(f!) => match f!(req) {
				Ok(res) => Respond(res)
				Err(e) => Failed(Str.inspect(e))
			}
			Err(MissingField) => Unhandled
		}
		Scheduled(s) => match w.?scheduled! {
			Ok(f!) => done(f!(s))
			Err(MissingField) => Unhandled
		}
		Queue(batch) => match w.?queue! {
			Ok(f!) => done(f!(batch))
			Err(MissingField) => Unhandled
		}
		Email(mail) => match w.?email! {
			Ok(f!) => done(f!(mail))
			Err(MissingField) => Unhandled
		}
		Tail(items) => match w.?tail! {
			Ok(f!) => done(f!(items))
			Err(MissingField) => Unhandled
		}
		Other({ kind, payload }) => match w.?other! {
			Ok(f!) => match f!(kind, payload) {
				Ok(v) => Reply(v)
				Err(e) => Failed(Str.inspect(e))
			}
			Err(MissingField) => Unhandled
		}
		# RPC of the default entry point ("default") or of a named one: the handler of the method (MODULES.md 8).
		Rpc({ entrypoint, method, arg }) => {
			handlers = if entrypoint == "default" (w.?rpc ?? []) else match (w.?entrypoints ?? []).find_first(|ep| ep.name == entrypoint) {
				Ok(ep) => ep.rpc
				Err(_) => []
			}
			match handlers.find_first(|h| h.name == method) {
				Ok(h) => {
					run! = h.run!
					match run!({}, arg) {
						Ok(bytes) => Reply(Packed(bytes))
						Err(text) => Failed(text)
					}
				}
				Err(_) => Unhandled
			}
		}
		EntrypointFetch({ entrypoint, request }) => match (w.?entrypoints ?? []).find_first(|ep| ep.name == entrypoint) {
			Ok(ep) => {
				f! = ep.fetch!
				match f!(request) {
					Respond(res) => Respond(res)
					Failed(text) => Failed(text)
					Unhandled => Unhandled
				}
			}
			Err(_) => Unhandled
		}
		Object({ class, id, event }) => match (w.?objects ?? []).find_first(|c| c.name == class) {
			Ok(c) => {
				run! = c.run!
				run!(id, event)
			}
			Err(_) => Unhandled
		}
		Manifest => Reply(manifest(w))
	}
}

done : Try({}, e) -> Worker.Outcome
done = |r| match r {
	Ok({}) => Done
	Err(e) => Failed(Str.inspect(e))
}

## The names of classes and methods (API.md AQ10): `{ default: [methods], objects: { Name: { handlers, methods } },
## entrypoints: { Name: { handlers, methods } } }`. The shim defines a JS method only for a name in it (MODULES.md 3).
manifest : Worker(e) -> Js
manifest = |w| {
	texts = |names| Arr(names.map(|n| Text(n)))
	class_of = |handlers, methods| Obj([("handlers", texts(handlers)), ("methods", texts(methods))])
	Obj([
		("default", texts((w.?rpc ?? []).map(|h| h.name))),
		("objects", Obj((w.?objects ?? []).map(|c| (c.name, class_of(c.handlers, c.methods))))),
		("entrypoints", Obj((w.?entrypoints ?? []).map(|ep| (ep.name, class_of(ep.handlers, ep.rpc.map(|h| h.name)))))),
	])
}
