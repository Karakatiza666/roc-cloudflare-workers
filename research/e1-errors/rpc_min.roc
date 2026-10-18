app [event!] { pf: platform "../../platform/main.roc" }

## Probe (step 8h): the smallest app with a typed RPC error on both sides.
import pf.Worker
import pf.Rpc
import pf.Service
import pf.Response

close_out : Rpc({}, U64, [StillOpen])
close_out = Rpc.method("close_out")

close_out! : {}, {} => Try(U64, [StillOpen])
close_out! = |{}, {}| Err(StillOpen)

fetch! = |_req| {
	text = match Service.binding("SELF").call!(close_out, {}) {
		Ok(n) => n.to_str()
		Err(Remote(StillOpen)) => "still open"
		Err(RpcErr(t)) => t.message
		Err(BadData(t)) => t
	}
	Ok(Response.from_text(200, text))
}

worker = Worker.new({ fetch!, rpc: [close_out.on(close_out!)] })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
