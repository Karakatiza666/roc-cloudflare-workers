app [event!] {
	pf: platform "../../bench/platform/main.roc",
	cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.1.0/9QL2dCyq7bcmvAEZfDFwi8kBvWLCZpEMS4WQYnZisezw.tar.zst",
}

## Probe: the app has its own `cbor` dependency, the same URL as the platform.
import pf.Worker
import pf.Request
import pf.Response
import cbor.Cbor

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	bytes = Cbor.encode({ id: 7.I64, name: "x" })
	got : Try({ id : I64, name : Str }, _)
	got = Cbor.parse(bytes)
	Ok(Response.from_text(200, Str.inspect(got)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
