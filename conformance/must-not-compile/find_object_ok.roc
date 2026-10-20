app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of find_object_bad.roc: `find!` has no `NotFound` in the outer error, so the closed error type compiles.
import pf.Worker
import pf.Object
import pf.Response
import pf.Io

count : Object.Cell(I64)
count = Object.cell("count")

read! : Object.Self => Try(I64, [BadData(Str), StorageErr(Io.Thrown)])
read! = |self| match count.find!(self)? {
	Ok(v) => Ok(v)
	Err(NotFound) => Ok(0)
}

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
