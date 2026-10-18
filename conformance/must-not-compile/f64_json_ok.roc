app [event!] { pf: platform "../../bench/platform/main.roc" }

## A record with an `F64` field goes to `Kv.json` and `Response.from_json` (MODULES.md 15): `Json.Encodable(enc)` has an
## open error. With `Encodable([])` it does not compile. `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Request
import pf.Response
import pf.Kv

Ratio : { name : Str, ratio : F64 }

ratios : Kv(Ratio)
ratios = Kv.json("KV")

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	r : Ratio
	r = { name: "a", ratio: 0.5 }
	match ratios.put!("k", r) {
		Ok({}) => Ok(Response.from_json(200, r))
		Err(_) => Ok(Response.from_status(500))
	}
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
