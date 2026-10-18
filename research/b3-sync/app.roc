app [event!] { pf: platform "../../platform/main.roc" }

## Step 8h wave B, issue 5: a project with one Durable Object class, one D1 database and one cron. `run.sh` builds it,
## makes its worker.js and checks its wrangler.toml with `roc-cloudflare-workers sync`, and runs it in `wrangler dev`.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Object
import pf.Rpc
import pf.Log
import pf.Sql

db = D1.binding("DB")

counters = Object.namespace("COUNTERS", { class: "Counter" })

bump : Rpc(U64, U64, Rpc.NoErr)
bump = Rpc.method("bump")

total = Object.cell("total")

bump! : Object.Self, U64 => Try(U64, Rpc.NoErr)
bump! = |self, by| {
	n = (total.get_or!(self, 0.U64) ?? 0) + by
	_ = total.set!(self, n)
	Ok(n)
}

counter = Object.class("Counter", { rpc: [bump.on(bump!)] })

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["d1"] => {
		row : { n : I64 }
		row = db.first!("SELECT 41 + 1 AS n", Sql.none)?
		Ok(Response.from_text(200, "d1 ${row.n.to_str()}"))
	}
	_ => {
		n = counters.named("one").call!(bump, 0)?
		Ok(Response.from_text(200, "count ${n.to_str()}"))
	}
}

tick! : Worker.Scheduled => Try({}, _)
tick! = |s| {
	n = counters.named("one").call!(bump, 1)?
	Log.info!("tick", { cron: s.cron, n })
	Ok({})
}

worker = Worker.new({
	fetch!: fetch!,
	objects: [counter],
	bindings: [db.declare(), counters.declare()],
	crons: [Worker.cron("*/5 * * * *", tick!)],
})

event! = |e| worker.event!(e)
