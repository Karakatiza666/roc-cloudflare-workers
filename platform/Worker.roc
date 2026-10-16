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
import cbor.Cbor

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

	## One item of the batch of a Tail Worker (MODULES.md 3): plain data, read as CBOR (MC5, PLAN.md 8f).
	## `parser_for : _`: a nominal type opts in to the derived parser (MODULES.md 15). The request headers are records of
	## `name` and `value`, not `Header` of `roc-lang/http`: that type has no `parser_for` (PLAN.md 8b O1).
	TraceItem := {
		script_name : Try(Str, [Missing]),
		outcome : Str,
		event_timestamp_ms : Try(U64, [Missing]),
		event : Try({ request : { method : Str, url : Str, headers : List({ name : Str, value : Str }), cf : Try(Request.Cf, [Missing]) }, response : Try({ status : U16 }, [Missing]) }, [Missing]),
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

## The CBOR that `js/events.js` writes for two trace items (`research/f2-queue/trace_bytes.mjs`): a fetch that threw, and a cron
## run. The derived parser reads a `Try` field as the value, and as `Err(Missing)` when the key is absent.
trace_bytes : List(U8)
trace_bytes = [0x82, 0xa6, 0x6b, 0x73, 0x63, 0x72, 0x69, 0x70, 0x74, 0x5f, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x77, 0x67, 0x6f, 0x75, 0x74, 0x63, 0x6f, 0x6d, 0x65, 0x69, 0x65, 0x78, 0x63, 0x65, 0x70, 0x74, 0x69, 0x6f, 0x6e, 0x72, 0x65, 0x76, 0x65, 0x6e, 0x74, 0x5f, 0x74, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61, 0x6d, 0x70, 0x5f, 0x6d, 0x73, 0x1b, 0x00, 0x00, 0x01, 0x8b, 0xcf, 0xe5, 0x68, 0x00, 0x65, 0x65, 0x76, 0x65, 0x6e, 0x74, 0xa2, 0x67, 0x72, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0xa3, 0x66, 0x6d, 0x65, 0x74, 0x68, 0x6f, 0x64, 0x63, 0x47, 0x45, 0x54, 0x63, 0x75, 0x72, 0x6c, 0x69, 0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f, 0x78, 0x2f, 0x67, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72, 0x73, 0x81, 0xa2, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61, 0x65, 0x76, 0x61, 0x6c, 0x75, 0x65, 0x61, 0x62, 0x68, 0x72, 0x65, 0x73, 0x70, 0x6f, 0x6e, 0x73, 0x65, 0xa1, 0x66, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x19, 0x01, 0xf4, 0x64, 0x6c, 0x6f, 0x67, 0x73, 0x81, 0xa3, 0x6c, 0x74, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61, 0x6d, 0x70, 0x5f, 0x6d, 0x73, 0x05, 0x65, 0x6c, 0x65, 0x76, 0x65, 0x6c, 0x63, 0x6c, 0x6f, 0x67, 0x67, 0x6d, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x67, 0x5b, 0x22, 0x61, 0x22, 0x2c, 0x31, 0x5d, 0x6a, 0x65, 0x78, 0x63, 0x65, 0x70, 0x74, 0x69, 0x6f, 0x6e, 0x73, 0x81, 0xa3, 0x6c, 0x74, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61, 0x6d, 0x70, 0x5f, 0x6d, 0x73, 0x06, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x65, 0x45, 0x72, 0x72, 0x6f, 0x72, 0x67, 0x6d, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x64, 0x62, 0x6f, 0x6f, 0x6d, 0xa4, 0x67, 0x6f, 0x75, 0x74, 0x63, 0x6f, 0x6d, 0x65, 0x62, 0x6f, 0x6b, 0x72, 0x65, 0x76, 0x65, 0x6e, 0x74, 0x5f, 0x74, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61, 0x6d, 0x70, 0x5f, 0x6d, 0x73, 0x1b, 0x00, 0x00, 0x01, 0x8b, 0xcf, 0xe5, 0x68, 0x01, 0x64, 0x6c, 0x6f, 0x67, 0x73, 0x80, 0x6a, 0x65, 0x78, 0x63, 0x65, 0x70, 0x74, 0x69, 0x6f, 0x6e, 0x73, 0x80]

expect {
	items : Try(List(Worker.TraceItem), _)
	items = Cbor.parse(trace_bytes)
	match items {
		Ok([fetched, _cron]) => {
			request_ok = match fetched.event {
				Ok(e) => e.request.method == "GET" and e.request.url == "http://x/" and e.request.headers == [{ name: "a", value: "b" }] and e.request.cf == Err(Missing) and e.response == Ok({ status: 500 })
				Err(Missing) => Bool.False
			}
			request_ok and fetched.script_name == Ok("w") and fetched.outcome == "exception" and fetched.event_timestamp_ms == Ok(1_700_000_000_000) and fetched.logs == [{ timestamp_ms: 5, level: "log", message: "[\"a\",1]" }] and fetched.exceptions == [{ timestamp_ms: 6, name: "Error", message: "boom" }]
		}
		_ => Bool.False
	}
}

## A cron run has no `event` (MODULES.md 3): `Err(Missing)`, as a missing `script_name`.
expect {
	items : Try(List(Worker.TraceItem), _)
	items = Cbor.parse(trace_bytes)
	match items {
		Ok([_, cron]) => cron.event == Err(Missing) and cron.script_name == Err(Missing) and cron.outcome == "ok" and cron.logs == []
		_ => Bool.False
	}
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
