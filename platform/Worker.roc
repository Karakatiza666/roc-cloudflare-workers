## The entry types (API.md 10.1) and the `Worker` wrapper (MODULES.md 3): `Worker.new` takes a record of handlers, all
## optional, each with the result type of its kind and its own error type. It turns each `Err(e)` into text
## (`Str.inspect(e)`), so the `Worker` has no type parameter. `rpc`, `entrypoints` and `objects` (PLAN.md 8f) erase their
## types the same way.
import Io
import Rpc
import Js
import Request
import Response
import Queue
import Email
import Object
import Service
import D1
import Kv
import cbor.Cbor

## `handlers`: the handlers of the default export that the app gives (the manifest). `own!`: runs the events of those
## handlers (`Fetch`, `Scheduled`, `Queue`, `Email`, `Tail`, `Other`). `bindings` and `crons`: for the manifest only.
Worker :: {
	handlers : List(Str),
	own! : Worker.Event => Worker.Outcome,
	rpc : List(Rpc.Handler({})),
	entrypoints : List(Rpc.Entrypoint),
	objects : List(Object.Class),
	bindings : List(Worker.Binding),
	crons : List(Str),
}.{

	## The handlers of the app. A function, not a record literal: each handler keeps its own error type until here.
	new : {
		fetch! ?: Request => Try(Response, e1),
		scheduled! ?: Worker.Scheduled => Try({}, e2),
		queue! ?: Queue.Batch => Try({}, e3),
		email! ?: Email.Mail => Try({}, e4),
		tail! ?: List(Worker.TraceItem) => Try({}, e5),
		other! ?: Str, Js => Try(Js, e6),
		rpc ?: List(Rpc.Handler({})),
		entrypoints ?: List(Rpc.Entrypoint),
		objects ?: List(Object.Class),
		bindings ?: List(Worker.Binding),
		crons ?: List(Worker.Cron),
	} -> Worker
	new = |h| {
		crons = h.?crons ?? []
		given = [("fetch", h.?fetch!.is_ok()), ("scheduled", h.?scheduled!.is_ok()), ("queue", h.?queue!.is_ok()), ("email", h.?email!.is_ok()), ("tail", h.?tail!.is_ok())]
		Worker.{
			handlers: given.keep_oks(|(name, on)| if (on) Ok(name) else Err(NotGiven)),
			own!: |ev| match ev {
				Fetch(req) => match h.?fetch! {
					Ok(f!) => match f!(req) {
						Ok(res) => Respond(res)
						Err(e) => Failed(Str.inspect(e))
					}
					Err(MissingField) => Unhandled
				}
				# The handler of the cron first, then `scheduled!` (MODULES.md 3).
				Scheduled(s) => match crons.find_first(|c| c.cron == s.cron) {
					Ok(c) => {
						run! = c.run!
						run!(s)
					}
					Err(_) => match h.?scheduled! {
						Ok(f!) => done(f!(s))
						Err(MissingField) => Unhandled
					}
				}
				Queue(batch) => match h.?queue! {
					Ok(f!) => done(f!(batch))
					Err(MissingField) => Unhandled
				}
				Email(mail) => match h.?email! {
					Ok(f!) => done(f!(mail))
					Err(MissingField) => Unhandled
				}
				Tail(items) => match h.?tail! {
					Ok(f!) => done(f!(items))
					Err(MissingField) => Unhandled
				}
				Other({ kind, payload }) => match h.?other! {
					Ok(f!) => match f!(kind, payload) {
						Ok(v) => Reply(v)
						Err(e) => Failed(Str.inspect(e))
					}
					Err(MissingField) => Unhandled
				}
				_ => Unhandled
			},
			rpc: h.?rpc ?? [],
			entrypoints: h.?entrypoints ?? [],
			objects: h.?objects ?? [],
			bindings: h.?bindings ?? [],
			crons: crons.map(|c| c.cron),
		}
	}

	## A handler for one cron expression (`triggers.crons` of the Wrangler config). A run of another cron goes to
	## `scheduled!`. The expression is in the manifest, so `roc-cloudflare-workers sync` checks the config.
	cron : Str, (Worker.Scheduled => Try({}, e)) -> Worker.Cron
	cron = |expr, f!| { cron: expr, run!: |s| done(f!(s)) }

	## A cron handler with its error type erased.
	Cron : { cron : Str, run! : Worker.Scheduled => Worker.Outcome }

	## A binding that the app uses (`db.declare()`, `rooms.declare()`, ...), for the manifest: the name in `env`, the
	## kind, and the settings of the kind (`class` and `script` of an object namespace, `service` and `entrypoint` of a
	## service). The shim checks at load that `env` has each one with its kind.
	Binding : { name : Str, kind : Str, props : List((Str, Str)) }

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
	Scheduled :: { cron : Str, time_ms : U64 }.{

		## Plain data (MC13): a test can make one.
		new : { cron : Str, time_ms : U64 } -> Worker.Scheduled
		new = |r| Worker.Scheduled.{ cron: r.cron, time_ms: r.time_ms }

		cron : Worker.Scheduled -> Str
		cron = |x| x.cron

		time_ms : Worker.Scheduled -> U64
		time_ms = |x| x.time_ms

		## `controller.noRetry()`, one `call!` with no wait. The shim never calls it by itself (MODULES.md 3).
		## A throw is dropped: only a `Worker.Scheduled` of a `Scheduled` event has a controller.
		no_retry! : Worker.Scheduled => {}
		no_retry! = |_s| {
			_ = Js.call!([Call(Root("event"), "noRetry", [])])
			{}
		}
	}

	## One item of the batch of a Tail Worker (MODULES.md 3): plain data, read as CBOR (MC5, PLAN.md 8f).
	## `parser_for : _`: a nominal type opts in to the derived parser (MODULES.md 15). The request headers are records of
	## `name` and `value`, not `Header` of `roc-lang/http`: that type has no `parser_for` (PLAN.md 8b O1).
	TraceItem :: {
		script_name : Try(Str, [Missing]),
		outcome : Str,
		event_timestamp_ms : Try(U64, [Missing]),
		event : Try({ request : { method : Str, url : Str, headers : List({ name : Str, value : Str }), cf : Try(Request.Cf, [Missing]) }, response : Try({ status : U16 }, [Missing]) }, [Missing]),
		logs : List({ timestamp_ms : U64, level : Str, message : Str }),
		exceptions : List({ timestamp_ms : U64, name : Str, message : Str }),
	}.{
		parser_for : _

		script_name : Worker.TraceItem -> Try(Str, [Missing])
		script_name = |x| x.script_name

		outcome : Worker.TraceItem -> Str
		outcome = |x| x.outcome

		event_timestamp_ms : Worker.TraceItem -> Try(U64, [Missing])
		event_timestamp_ms = |x| x.event_timestamp_ms

		event : Worker.TraceItem -> Try({ request : { method : Str, url : Str, headers : List({ name : Str, value : Str }), cf : Try(Request.Cf, [Missing]) }, response : Try({ status : U16 }, [Missing]) }, [Missing])
		event = |x| x.event

		logs : Worker.TraceItem -> List({ timestamp_ms : U64, level : Str, message : Str })
		logs = |x| x.logs

		exceptions : Worker.TraceItem -> List({ timestamp_ms : U64, name : Str, message : Str })
		exceptions = |x| x.exceptions
	}

	## The one entry, made from the handlers that the app gives (`event! = |e| worker.event!(e)`).
	## A missing handler gives `Unhandled`. An `Err(e)` gives `Failed` with `Str.inspect(e)`.
	event! : Worker, Worker.Event => Worker.Outcome
	event! = |w, ev| match ev {
		Fetch(_) | Scheduled(_) | Queue(_) | Email(_) | Tail(_) | Other(_) => {
			own! = w.own!
			own!(ev)
		}
		# RPC of the default entry point ("default") or of a named one: the handler of the method (MODULES.md 8).
		Rpc({ entrypoint, method, arg }) => {
			handlers = if (entrypoint == "default") w.rpc else match w.entrypoints.find_first(|ep| ep.name == entrypoint) {
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
		EntrypointFetch({ entrypoint, request }) => match w.entrypoints.find_first(|ep| ep.name == entrypoint) {
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
		Object({ class, id, event }) => match w.objects.find_first(|c| c.name == class) {
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

## The names of classes and methods (API.md AQ10): `{ default: { handlers, methods }, objects: { Name: { handlers,
## methods } }, entrypoints: { Name: { handlers, methods } }, bindings: [{ name, kind, ... }], crons: [...] }`. The shim
## defines a JS method only for a name in it (MODULES.md 3). The handlers of the default export: the fields that the app
## gives (QO5 of PLAN.md 8f, part 2).
manifest : Worker -> Js
manifest = |w| {
	texts = |names| Arr(names.map(|n| Text(n)))
	class_of = |handlers, methods| Obj([("handlers", texts(handlers)), ("methods", texts(methods))])
	binding_of = |b| Obj([("name", Text(b.name)), ("kind", Text(b.kind))].concat(b.props.map(|(k, v)| (k, Text(v)))))
	Obj([
		("default", class_of(w.handlers, w.rpc.map(|h| h.name))),
		("objects", Obj(w.objects.map(|c| (c.name, class_of(c.handlers, c.methods))))),
		("entrypoints", Obj(w.entrypoints.map(|ep| (ep.name, class_of(ep.handlers, ep.rpc.map(|h| h.name)))))),
		("bindings", Arr(w.bindings.map(binding_of))),
		("crons", texts(w.crons)),
	])
}

## QO5: the handlers of the default export are the fields that the app gives, so the shim defines `queue` only here.
expect {
	consume! = |_batch| Ok({})
	w = Worker.new({ queue!: consume! })
	manifest(w) == Obj([("default", Obj([("handlers", Arr([Text("queue")])), ("methods", Arr([]))])), ("objects", Obj([])), ("entrypoints", Obj([])), ("bindings", Arr([])), ("crons", Arr([]))])
}

# The tests below are for the bindings and crons of Worker.new (MODULES.md 3).
# A binding of the manifest: the name, the kind and the props (`Object.Namespace.declare` and `Service.declare` give the props).
expect {
	w = Worker.new({
		bindings: [
			D1.binding("DB").declare(),
			Kv.text("KV").declare(),
			Object.namespace("ROOMS", { class: Object.class("Room", {}) }).declare(),
			Object.namespace_remote("FAR", { class: "Far", script: "other" }).declare(),
			Object.namespace("FAR2", { class: Object.class("Far2", {}), script: "other" }).declare(),
			Kv.text("CFG").cell("c").declare(),
		],
		crons: [Worker.cron("*/5 * * * *", |_s| Ok({})), Worker.cron("0 0 * * *", |_s| Ok({}))],
	})
	manifest(w) == Obj([
		("default", Obj([("handlers", Arr([])), ("methods", Arr([]))])),
		("objects", Obj([])),
		("entrypoints", Obj([])),
		(
			"bindings",
			Arr([
				Obj([("name", Text("DB")), ("kind", Text("d1"))]),
				Obj([("name", Text("KV")), ("kind", Text("kv"))]),
				Obj([("name", Text("ROOMS")), ("kind", Text("object")), ("class", Text("Room"))]),
				Obj([("name", Text("FAR")), ("kind", Text("object")), ("class", Text("Far")), ("script", Text("other"))]),
				Obj([("name", Text("FAR2")), ("kind", Text("object")), ("class", Text("Far2")), ("script", Text("other"))]),
				Obj([("name", Text("CFG")), ("kind", Text("kv"))]),
			]),
		),
		("crons", Arr([Text("*/5 * * * *"), Text("0 0 * * *")])),
	])
}

# A service binding with `service` and `entrypoint` has them in the manifest. A plain one has only the name and the kind.
expect {
	w = Worker.new({ bindings: [Service.binding("A").declare(), Service.binding_with("B", { service: "svc", entrypoint: "Admin" }).declare()] })
	manifest(w) == Obj([
		("default", Obj([("handlers", Arr([])), ("methods", Arr([]))])),
		("objects", Obj([])),
		("entrypoints", Obj([])),
		(
			"bindings",
			Arr([
				Obj([("name", Text("A")), ("kind", Text("service"))]),
				Obj([("name", Text("B")), ("kind", Text("service")), ("service", Text("svc")), ("entrypoint", Text("Admin"))]),
			]),
		),
		("crons", Arr([])),
	])
}

# A cron handler is not a handler of the default export: `handlers` does not have `scheduled`.
expect {
	w = Worker.new({ crons: [Worker.cron("* * * * *", |_s| Ok({}))] })
	w.handlers == []
}

# The order of a cron run (cron first, else scheduled!, else Unhandled) calls `own!`, an effect, so an expect cannot run it:
# conformance/checks/cron.mjs tests it.
