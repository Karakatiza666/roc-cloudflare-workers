app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: `get!` has `NotFound` in its error, so the closed error type of `find_object_ok.roc` does not fit.
import pf.Worker
import pf.Object
import pf.Response
import pf.Io

count : Object.Cell(I64)
count = Object.cell("count")

read! : Object.Self => Try(I64, [Infra([BadData(Str), StorageErr(Io.Thrown)])])
read! = |self| count.get!(self)

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
