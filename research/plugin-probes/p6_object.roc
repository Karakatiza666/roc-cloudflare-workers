app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc

counters = Object.namespace("COUNTERS")

increment : Rpc({ by : I64 }, I64)
increment = Rpc.method("increment")

count : Object.Cell(I64)
count = Object.cell("count")

counter = Object.class("Counter", {
	init!: |self| {
		_ = self.sql_run!("create table if not exists hits (at integer)", [])?
		Ok({})
	},
	fetch!: |self, _req| {
		n = count.get!(self) ?? 0
		Ok(Response.from_text(200, n.to_str()))
	},
	rpc: [
		increment.on(|self, { by }| {
			n = (count.get!(self) ?? 0) + by
			count.set!(self, n)?
			Ok(n)
		}),
	],
})

fetch! = |req| match req.segments() {
	["inc"] => {
		n = counters.named("global").call!(increment, { by: 1 })?
		Ok(Response.from_text(200, n.to_str()))
	}
	["show"] => counters.named("global").fetch!(req)
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch!, objects: [counter] }

event! = |e| worker.event!(e)
