app [event!] { pf: platform "plat/main_expose_cbor.roc" }

## Probe: the platform root lists `Cbor` (`import cbor.Cbor` in main.roc) in exposes. The app imports `pf.Cbor`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Cbor

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	raw = Cbor.encode({ id: 7.I64 })
	got : Try({ id : I64 }, _)
	got = Cbor.parse(raw)
	Ok(Response.from_text(200, Str.inspect(got)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
