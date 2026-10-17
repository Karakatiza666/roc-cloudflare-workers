app [event!] { pf: platform "plat/main_root_alias.roc" }

## Probe: the platform root declares `Bytes : Cbor.Bytes` and lists `Bytes` in exposes. The app imports `pf.Bytes`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Bytes

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	b : Bytes
	b = Bytes.([1])
	Ok(Response.from_text(200, Str.inspect(b)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
