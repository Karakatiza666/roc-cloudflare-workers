app [event!] {
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "platform/main.roc",
}

## `on_trap` (MODULES.md 3, design note trap-response): the fixed responses of `fetch` for a trap and other failures. The
## form of the registry (problem details, `application/problem+json`), with a different title for each cause, so a test
## sees which entry the shim used. `alarm`, `cpu` and `event` have no entry: they get `default`.
## `bench/trap-test.mjs` (Node) and `conformance/checks/trap.mjs` (Miniflare) send the requests below.
import http.Header
import pf.Worker
import pf.Request
import pf.Response
import pf.Js
import pf.Ctx
import pf.Object
import pf.Rpc

## | Request | Answer |
## | --- | --- |
## | GET /ok | 200 `ok` |
## | GET /crash | a `crash` |
## | GET /err | `Err(Boom)`: `Failed` |
## | GET /big/<mb> | holds a list of `mb` MiB, then 200 |
## | GET /wait | waits for the op `never` (a promise that does not resolve) |
## | GET /after | 200 `early` with `Response.after`, then a `crash` in the work |
## | GET /pass | `Ctx.pass_through!`, then a `crash` |
route! : Request => Try(Response, _)
route! = |req| match req.segments() {
	["ok"] => Ok(Response.from_text(200, "ok"))
	["crash"] => crash "the crash text of app_trap"
	["err"] => Err(Boom)
	["big", mb] => {
		n = U64.from_str(mb) ?? 0
		held = List.repeat(7.U8, n * 1048576)
		Ok(Response.from_text(200, "held ${held.len().to_str()}"))
	}
	["wait"] => {
		_ = Js.await!([Call(Root("ops"), "never", [])])
		Ok(Response.from_text(200, "woke"))
	}
	["after"] => Ok(Response.from_text(200, "early").after(|| crash "a crash in the work after the response"))
	["pass"] => {
		Ctx.pass_through!()?
		crash "a crash after pass_through!"
	}
	_ => Ok(Response.from_status(404))
}

## The registry form (design note trap-response 5.1).
problem : U16, Str, List(Header) -> Worker.Fixed
problem = |status, title, extra| {
	status,
	headers: [Header.{ name: "content-type", value: "application/problem+json" }, Header.{ name: "cache-control", value: "no-store" }].concat(extra),
	body: Str.to_utf8("{\"type\":\"/errors/internal\",\"title\":\"${title}\",\"status\":${status.to_str()}}"),
}

box_class : Object.Class([])
box_class = Object.class("Box", { fetch!: |_self, req| route!(req) })

worker = Worker.new({
	fetch!: route!,
	objects: [box_class.erase()],
	entrypoints: [Rpc.entrypoint("Ep", { fetch!: route! })],
	on_trap: {
		default: problem(500, "Internal error", []),
		crashed: problem(500, "Crashed", []),
		oom: problem(503, "Out of memory", [Header.{ name: "retry-after", value: "7" }]),
		shed: problem(503, "Shed", []),
		deadline: problem(504, "Deadline", []),
		cancelled: problem(503, "Cancelled", []),
		failed: problem(502, "Failed", []),
	},
})

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
