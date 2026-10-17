app [event!] { pf: platform "plat/main_expose_as.roc" }

## Probe: the platform lists `Cbor as Codec2` in exposes. The app imports `pf.Codec2`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Codec2

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	raw = Codec2.encode({ id: 7.I64 })
	got : Try({ id : I64 }, _)
	got = Codec2.parse(raw)
	Ok(Response.from_text(200, Str.inspect(got)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
