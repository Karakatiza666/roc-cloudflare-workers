app [event!] { pf: platform "platform/main.roc" }

## PLAN.md 8b (first half): the events of API.md 10.1 through the `Worker` wrapper (MODULES.md 3).
## `bench/entry-test.mjs` (Node) and `bench/entry-workerd.mjs` (workerd) send the requests and the cron runs below.
import pf.Worker
import pf.Request
import pf.Response
import pf.Js
import pf.Queue

## | Request | Answer |
## | --- | --- |
## | POST /echo | the body bytes, as they came |
## | GET /headers | each request header whose name starts with `x-h-`, as a response header |
## | GET /missing | 404 |
## | GET /err | `Err(Boom(42))`: `Failed` |
## | GET /crash | a `crash` with a known text |
## | GET /unhandled | a `Worker` with no `fetch!`: `Unhandled` |
## | POST /json | `{ "n": n }` gives `{ "n": n + 1 }` (`Request.json!`, `Response.from_json`) |
## | GET /cf | the fields of `Request.Cf` that the test sets, as text |
fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method(), req.segments()) {
	(POST, ["echo"]) => {
		bytes = req.bytes!()?
		Ok(Response.from_bytes(200, "application/octet-stream", bytes))
	}
	(POST, ["json"]) => {
		v : { n : U64 }
		v = req.json!()?
		Ok(Response.from_json(200, { n: v.n + 1 }))
	}
	(GET, ["headers"]) => Ok(Response.from_status(200).with_headers(req.headers().keep_if(|h| h.name.starts_with("x-h-"))))
	(GET, ["err"]) => Err(Boom(42.U64))
	(GET, ["crash"]) => crash "the crash text of app_events"
	(GET, ["cf"]) => Ok(Response.from_text(200, cf_text(req)))
	_ => Ok(Response.from_status(404))
}

## The cron of the test decides the result. A `time_ms` that is not the one of the test is an error.
scheduled! : Worker.Scheduled => Try({}, _)
scheduled! = |s| match s.cron() {
	"*/5 * * * *" => if s.time_ms() == 1_700_000_000_000 Ok({}) else Err(WrongTime(s.time_ms()))
	"fail" => Err(Failing)
	"noretry" => {
		s.no_retry!()
		Err(Failing)
	}
	other => Err(UnknownCron(other))
}

## `makeHandler(module, { other: ["ping"] })`: the kind and the payload back to the JS caller.
other! : Str, Js => Try(Js, _)
other! = |kind, payload| match kind {
	"ping" => Ok(Obj([("kind", Text(kind)), ("got", payload)]))
	_ => Err(UnknownKind(kind))
}

cf_text : Request -> Str
cf_text = |req| match req.cf() {
	Ok(cf) => {
		show = |t| match t {
			Ok(v) => "Ok(${v})"
			Err(Missing) => "Missing"
		}
		asn = match cf.asn {
			Ok(n) => "Ok(${n.to_str()})"
			Err(Missing) => "Missing"
		}
		rtt = match cf.client_tcp_rtt_ms {
			Ok(n) => "Ok(${n.to_str()})"
			Err(Missing) => "Missing"
		}
		eu = if cf.is_eu_country "eu" else "not eu"
		"colo=${show(cf.colo)} city=${show(cf.city)} asn=${asn} rtt=${rtt} ${eu}"
	}
	Err(_) => "no cf"
}

## The event `Queue` (8f): the batch of one message that `bench/entry-workerd.mjs` sends.
queue! : Queue.Batch => Try({}, _)
queue! = |batch| if batch.queue() == "jobs" and batch.messages().len() == 1 Ok({}) else Err(WrongBatch(batch.queue()))

worker = Worker.new({ fetch!, scheduled!, queue!, other! })

## For the tests of a missing handler.
no_fetch = Worker.new({ scheduled!: scheduled! })

no_scheduled = Worker.new({ fetch!: fetch! })

event! : Worker.Event => Worker.Outcome
event! = |e| match e {
	Fetch(req) if req.segments() == ["unhandled"] => no_fetch.event!(e)
	Scheduled(s) if s.cron() == "none" => no_scheduled.event!(e)
	_ => worker.event!(e)
}
