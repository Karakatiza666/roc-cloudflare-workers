app [event!] { pf: platform "../../bench/platform/main.roc" }

## Probe: the platform lists `Cbor` (a module of its package `cbor`) in `exposes`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Cbor

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	bytes = Cbor.encode({ id: 7.I64, name: "x" })
	got : Try({ id : I64, name : Str }, _)
	got = Cbor.parse(bytes)
	Ok(Response.from_text(200, Str.inspect(got)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
