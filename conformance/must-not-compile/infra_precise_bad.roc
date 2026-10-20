app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile (N5 G1a): each platform function has its own `Infra([..])` tags. `Kv.get!` has no `SqlErr` (a tag of the
## object SQL), so the closed error type of `describe` (the tags of `Kv.get!`) has no arm for `Infra(SqlErr(_))`. The control is the
## same file without that arm: it compiles only when the error of `Kv.get!` fits the closed type (no tag of another function).
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Kv
import pf.Response
import pf.Io

describe : [NotFound, Infra([KvErr(Io.Thrown), BadData(Str), TooLarge])] -> Str
describe = |e| match e {
	NotFound => "none"
	Infra(KvErr(_)) => "kv"
	Infra(BadData(_)) => "bad"
	Infra(TooLarge) => "big"
	Infra(SqlErr(_)) => "sql"
}

read! : {} => Str
read! = |{}| match Kv.text("KV").get!("k") {
	Ok(v) => v
	Err(e) => describe(e)
}

fetch! = |_req| Ok(Response.from_text(200, read!({})))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
