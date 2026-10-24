app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Http
import pf.Io
import pf.D1
import pf.Kv
import pf.Body
import pf.Ctx
import pf.WebSocket
import pf.Time

db = D1.binding("DB")

cache = Kv.json("CACHE")

# A: Request built as a record
put_req = |url, b| Request.{ method: PUT, url, body: Bytes(b) }

# B: two at once
both! = |_| {
	(a, b) = Io.both!(Http.get("https://a.example"), Http.get("https://b.example"))?
	Ok(a.status + b.status)
}

# C: a stream after respond
stream! = |_| {
	{ body, writer } = Body.writer!({})?
	Ctx.respond!(Response.from_body(200, "text/event-stream", body))?
	writer.write_text!("data: hi\n\n")?
	writer.close!()
	Ok(Response.from_status(200))
}

# D: websocket echo
ws! = |req| {
	{ socket, response } = WebSocket.accept!(req)?
	Ctx.respond!(response)?
	loop! = |{}| match socket.receive!() {
		Ok(msg) => {
			_ = socket.send!(msg)
			loop!({})
		}
		Err(Closed(_)) => Ok({})
	}
	loop!({})?
	Ok(response)
}

# E: a timeout
timed! = |_| {
	r = Io.race!([Http.get("https://slow.example").map(|res| Got(res)), Time.sleep(5_000).map(|_| TimedOut)])
	match r.result {
		Ok(Got(res)) => Ok(res)
		Ok(TimedOut) => Ok(Response.from_status(504))
		Err(e) => Err(e)
	}
}

# F: Kv with no annotation
kv! = |_| {
	v = cache.get!("k")?
	Ok(Response.from_text(200, v.name))
}

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(GET, ["both"]) => {
		n = both!({})?
		Ok(Response.from_text(200, n.to_str()))
	}
	(GET, ["stream"]) => stream!({})
	(GET, ["ws"]) => ws!(req)
	(GET, ["timed"]) => timed!({})
	(GET, ["kv"]) => kv!({})
	(PUT, ["up"]) => {
		b = req.bytes!()?
		Http.send!(put_req("https://x.example", b))
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
