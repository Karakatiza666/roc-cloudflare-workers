app [event!] {
	pf: platform "../../bench/platform/main.roc",
}

## Must compile (MODULES.md 5.1, "Parameters"): roc-cbor 0.5.0 encodes a U128 (a bignum above 64 bits), so a U128 SQL
## parameter compiles. In I64 it binds; above I64 it is `BadParam` at run time (`checks/d1.mjs`). Before roc-cbor 0.5.0 it did not
## compile (no `encode_u128`). `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	_ = db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("a", 5.U128))
	Ok(Response.from_status(204))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
