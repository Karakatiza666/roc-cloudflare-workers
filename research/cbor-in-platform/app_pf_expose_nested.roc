app [event!] { pf: platform "plat/main_expose_nested.roc" }

## Probe: the platform lists `Cbor.Bytes` (a nested type of a package module) in exposes. The app imports `pf.Cbor`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Cbor

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	b : Cbor.Bytes
	b = Cbor.Bytes.([1])
	Ok(Response.from_text(200, Str.inspect(b)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
