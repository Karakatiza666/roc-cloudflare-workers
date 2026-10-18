app [event!] {
	pf: platform "../../bench/platform/main.roc",
}

## Must not compile (MODULES.md 5.1, "Parameters"): a U128 SQL parameter has no encoder to a SQL value.
## `conformance/must-not-compile.sh` runs `roc check` on it. The `_ok` file is the same with a type that is allowed.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	_ = db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("a", 5.U64))
	Ok(Response.from_status(204))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
