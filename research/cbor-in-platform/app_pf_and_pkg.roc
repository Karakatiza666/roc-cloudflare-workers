app [event!] {
	pf: platform "../../bench/platform/main.roc",
	cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.1.0/9QL2dCyq7bcmvAEZfDFwi8kBvWLCZpEMS4WQYnZisezw.tar.zst",
}

## Probe (2026-10-16): the app adds the package URL too, and uses both `pf.Cbor` (the platform module) and the package.
## The types are the same: a `pf.Cbor.Bytes` goes where a package `Bytes` is wanted, and bytes written by one are read by the other.
import pf.Worker
import pf.Request
import pf.Response
import pf.Cbor
import cbor.Cbor as CborPkg

takes_pkg : CborPkg.Bytes -> List(U8)
takes_pkg = |b| b.to_list()

takes_pf : Cbor.Bytes -> List(U8)
takes_pf = |b| b.to_list()

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	a : Cbor.Bytes
	a = Cbor.bytes([1, 2])
	b : CborPkg.Bytes
	b = CborPkg.Bytes.([3, 4])
	raw = CborPkg.encode({ x: a, y: b })
	back : Try({ x : CborPkg.Bytes, y : Cbor.Bytes }, _)
	back = Cbor.parse(raw)
	both : Try({ x : Cbor.Bytes, y : CborPkg.Bytes }, _)
	both = CborPkg.parse(Cbor.encode({ x: b, y: a }))
	Ok(Response.from_text(200, "${Str.inspect(takes_pkg(a))} ${Str.inspect(takes_pf(b))} ${Str.inspect(back)} ${Str.inspect(both)}"))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
