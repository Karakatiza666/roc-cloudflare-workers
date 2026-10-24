app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service

## The interface of the service.
lookup : Rpc({ key : Str }, [Found(Str), Unknown])
lookup = Rpc.method("lookup")

ping : Rpc({}, Str)
ping = Rpc.method("ping")

purge : Rpc({ prefix : Str }, U64)
purge = Rpc.method("purge")

other = Service.binding("OTHER")
admin = Service.binding("ADMIN")

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["lookup", key] => {
		reply = other.call!(lookup, { key: key })?
		match reply {
			Found(v) => Ok(Response.from_text(200, v))
			Unknown => Ok(Response.from_status(404))
		}
	}
	["ping"] => {
		s = other.call!(ping, {})?
		Ok(Response.from_text(200, s))
	}
	["admin"] => admin.fetch!(req)
	_ => Ok(Response.from_status(404))
}

admin_ep = Rpc.entrypoint("Admin", {
	fetch!: |_req| Ok(Response.from_text(200, "admin")),
	rpc: [
		purge.on(|_self, { prefix }| Ok(prefix.count_utf8_bytes())),
	],
})

worker = Worker.{
	fetch!,
	rpc: [
		lookup.on(|_self, { key }| if key == "a" Ok(Found("alpha")) else Ok(Unknown)),
		ping.on(|_self, {}| Ok("pong")),
	],
	entrypoints: [admin_ep],
}

event! = |e| worker.event!(e)
