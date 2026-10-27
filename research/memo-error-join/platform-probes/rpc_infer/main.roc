app [event!] { pf: platform "../../../../platform/main.roc" }
import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import Lib

handler! : {} => Try({}, [NotOpen])
handler! = |_| Err(NotOpen)

serves : List(Rpc.Serves(Lib.Room, {}))
serves = [Lib.m_inf.on_worker(handler!)]

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	r = Lib.svc.call!(Lib.m_inf, {})
	Ok(Response.from_text(200, Str.inspect(r)))
}

worker = Worker.new({ fetch!: fetch!, rpc: serves })
event! = |e| worker.event!(e)
