app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.WebSocket
import pf.Tcp
import pf.Hyperdrive
import pf.Ctx

rooms = Object.namespace("ROOMS")

# A class whose handlers never fail
quiet = Object.class("Quiet", {
	fetch!: |_self, _req| Ok(Response.from_text(200, "ok")),
})

# Worker-side echo
echo! : Request => Try(Response, _)
echo! = |req| {
	{ socket, response } = WebSocket.accept!(req)?
	Ctx.respond!(response)?
	loop! = |{}| match socket.receive!() {
		Ok(m) => {
			_ = socket.send!(m)
			loop!({})
		}
		Err(Closed(_)) => Ok({})
	}
	loop!({})?
	Ok(response)
}

tcp! = |{}| {
	sock = Tcp.connect!("example.com", 80)?
	sock.write!(Str.to_utf8("GET / HTTP/1.0\r\n\r\n"))?
	data = sock.read!()?
	sock.close!()
	Ok(data)
}

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["echo"] => echo!(req)
	["id"] => {
		id = rooms.named("lobby").id!()?
		u = rooms.unique!()
		Ok(Response.from_text(200, id))
	}
	["tcp"] => {
		d = tcp!({})?
		Ok(Response.from_bytes(200, "text/plain", d))
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch!, objects: [quiet] }

event! = |e| worker.event!(e)
