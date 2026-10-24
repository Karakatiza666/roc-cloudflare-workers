app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Time

rooms = Object.namespace("ROOMS")

Hit : { at : I64 }

room = Object.class("Room", {
	init!: |self| {
		_ = self.sql_run!("create table if not exists hits (at integer)", [])?
		Ok({})
	},
	fetch!: |self, _req| {
		now = Time.now_ms!({})
		_ = self.sql_run!("insert into hits (at) values (?)", [Int(now.to_i64_wrap())])?
		hits : List(Hit)
		hits = self.sql!("select at from hits", [])?
		self.set_alarm!(now + 60_000)?
		keys = self.list!()?
		Ok(Response.from_text(200, "${hits.len().to_str()} ${keys.len().to_str()}"))
	},
	alarm!: |self, info| {
		if info.retry_count > 3 {
			Ok({})
		} else {
			_ = self.sql_run!("delete from hits", [])?
			Ok({})
		}
	},
})

fetch! : Request => Try(Response, _)
fetch! = |req| rooms.named("lobby").fetch!(req)

worker = Worker.{ fetch!, objects: [room] }

event! = |e| worker.event!(e)
