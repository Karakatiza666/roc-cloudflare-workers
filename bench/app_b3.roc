app [event!] { pf: platform "platform/main.roc" }

## Step 8h wave B issue 5, a fixture of bench/cli-test.mjs (built by bench/build.sh).
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Kv
import pf.Object

## One class, a D1 database DB, a KV namespace KV, an object namespace COUNTERS, and one cron with no `scheduled!`.
db = D1.binding("DB")

kv = Kv.text("KV")

counters = Object.namespace("COUNTERS", { class: "Counter" })

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "b3"))

worker = Worker.new({
	fetch!: fetch!,
	objects: [Object.class("Counter", {})],
	bindings: [db.declare(), kv.declare(), counters.declare()],
	crons: [Worker.cron("*/5 * * * *", |_s| Err(FromCron))],
})

event! = |e| worker.event!(e)
