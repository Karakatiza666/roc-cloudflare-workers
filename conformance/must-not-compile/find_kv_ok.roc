app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of find_kv_bad.roc: `Kv.Cell.find!` has no `NotFound` in the outer error, so the closed error type compiles.
import pf.Worker
import pf.Kv
import pf.Response
import pf.Io

cell : Kv.Cell(Str)
cell = Kv.text("KV").cell("c")

read! : {} => Try(Str, [Infra([KvErr(Io.Thrown), BadData(Str), TooLarge])])
read! = |{}| match cell.find!()? {
	Ok(v) => Ok(v)
	Err(NotFound) => Ok("")
}

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
