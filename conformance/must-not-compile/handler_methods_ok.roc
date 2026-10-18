app [event!] { pf: platform "../../bench/platform/main.roc" }

## A control (8h wave C): an unannotated `fetch!` that reads the opaque `Request` through methods compiles. The type of `req`
## comes from `Worker.new`. `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Response

fetch! = |req| {
	m = req.method()
	segs = req.segments()
	data : Try({ name : Str }, _)
	data = req.json!()
	name = match data {
		Ok(d) => d.name
		Err(_) => "none"
	}
	Ok(Response.from_text(200, "${Str.inspect(m)} ${req.url()} ${segs.len().to_str()} ${name}"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
