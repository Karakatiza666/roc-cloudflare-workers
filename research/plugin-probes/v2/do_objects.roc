app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc
import pf.Time
import pf.Sql

Counter := []

counter_api : Rpc.Iface(Counter)
counter_api = Rpc.iface("Counter")

increment : Rpc(Counter, { by : I64 }, I64, [Infra(Rpc.Infra)])
increment = counter_api.method("increment")

count : Object.Cell(I64)
count = Object.cell("count")

Hit : { at : I64 }

counter : Object.Class(Counter)
counter = Object.class("Counter", {
	init!: |self| {
		_ = self.sql_run!("create table if not exists hits (at integer)", Sql.none)?
		Ok({})
	},
	fetch!: |self, _req| {
		now = Time.now_ms!()
		_ = self.sql_run!("insert into hits (at) values (?)", [now])?
		hits : List(Hit)
		hits = self.sql!("select at from hits", Sql.none)?
		self.set_alarm_in!(60_000)?
		n = count.get_or!(self, 0)?
		Ok(Response.from_text(200, "count ${n.to_str()}, hits ${hits.len().to_str()}"))
	},
	rpc: [
		increment.on(|self, { by }| {
			n = count.get_or!(self, 0)? + by
			count.set!(self, n)?
			Ok(n)
		}),
	],
	alarm!: |self, info| {
		if info.retry_count >= 3 {
			Ok({})
		} else {
			_ = self.sql_run!("delete from hits", Sql.none)?
			Ok({})
		}
	},
})

counters = Object.namespace("COUNTERS", { class: counter })

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["inc", name] => {
		n = counters.named(name).call!(increment, { by: 1 })?
		Ok(Response.from_text(200, n.to_str()))
	}
	["show", name] => Ok(counters.named(name).fetch!(req)?)
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({
	fetch!,
	objects: [counter.erase()],
	bindings: [counters.declare()],
})

event! = |e| worker.event!(e)
