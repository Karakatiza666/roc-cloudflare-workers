app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1/GcDNxAwPR5tSzqU8T2Kdj35CK3sQMRQDB8ywwfZKdrm.tar.zst" }

import pf.Worker
import pf.Response
import pf.Object
import pf.Rpc
import pf.Sql

Counter := []

counter_api : Rpc.Iface(Counter)
counter_api = Rpc.iface("Counter")

add_hit : Rpc(Counter, { at : U64 }, {}, [Infra(Rpc.Infra)])
add_hit = counter_api.method("add_hit")

counter : Object.Class(Counter)
counter = Object.class("Counter", {
	rpc: [
		add_hit.on(|self, { at }| {
			_ = self.sql_run!("insert into hits (at) values (?)", at)?
			Ok({})
		}),
	],
})

worker = Worker.new({ objects: [counter.erase()] })
event! = |e| worker.event!(e)
