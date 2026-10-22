app [event!] { pf: platform "../../bench/platform/main.roc" }

## Compiles (PLAN.md 8h item 1): each handler has its own error type. `fetch!` has `Try(Response, [])` (no error), `scheduled!`
## has a real error, and the handlers of one `Object.class` have three different error types. `conformance/must-not-compile.sh`
## runs `roc check` on it. It is the control of `worker_field_bad.roc`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Object

fetch! : Request => Try(Response, [])
fetch! = |_req| Ok(Response.from_text(200, "x"))

scheduled! : Worker.Scheduled => Try({}, [UnknownCron(Str)])
scheduled! = |s| Err(UnknownCron(s.cron()))

obj_init! : Object.Self => Try({}, [InitFailed])
obj_init! = |_self| Err(InitFailed)

obj_fetch! : Object.Self, Request => Try(Response, [NotFound(Str)])
obj_fetch! = |_self, req| Err(NotFound(req.url()))

obj_alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, [Retry(U32)])
obj_alarm! = |_self, info| Err(Retry(info.retry_count))

worker = Worker.new({
	fetch!: fetch!,
	scheduled!: scheduled!,
	objects: [Object.class("C", { init!: obj_init!, fetch!: obj_fetch!, alarm!: obj_alarm! }).erase()],
})

event! = |e| worker.event!(e)
