app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: `Kv.Cell.get!` has `NotFound` in its error, so the closed error type of `find_kv_ok.roc` does not fit.
import pf.Worker
import pf.Kv
import pf.Response
import pf.Io

cell : Kv.Cell(Str)
cell = Kv.text("KV").cell("c")

read! : {} => Try(Str, [KvErr(Io.Thrown), BadData(Str), TooLarge])
read! = |{}| cell.get!()

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
